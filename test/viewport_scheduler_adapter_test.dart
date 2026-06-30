import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:redslide/features/feed/domain/media_asset.dart';
import 'package:redslide/features/slideshow/domain/playlist_manager.dart';
import 'package:redslide/features/slideshow/domain/readiness_state.dart';
import 'package:redslide/features/slideshow/domain/viewport_scheduler_adapter.dart';

MediaAsset _asset({required String id}) {
  return MediaAsset(
    id: id,
    title: 'Test $id',
    author: 'test_author',
    score: 100,
    subreddit: 'test',
    mediaUrl: 'https://i.redd.it/$id.jpg',
    videoUrl: null,
    thumbnailUrl: null,
    isVideo: false,
    isGallery: false,
    nsfw: false,
    qualityScore: 50,
    galleryUrls: null,
    createdUtc: 1000000,
  );
}

Future<void> _mockPreload(String url, BuildContext context) async {}

void main() {
  group('A1: ViewportSchedulerAdapter _completed bounded growth', () {
    // Create a simple widget that can provide a BuildContext
    Widget _buildWrapper(Widget Function(BuildContext) buildContent) {
      return MaterialApp(
        home: Builder(builder: (ctx) {
          return buildContent(ctx);
        }),
      );
    }

    testWidgets('generation timer triggers _completed cleanup',
        (tester) async {
      late ViewportSchedulerAdapter adapter;
      late PlaylistManager playlist;

      await tester.pumpWidget(_buildWrapper((ctx) {
        playlist = PlaylistManager();
        playlist.append(List.generate(500, (i) => _asset(id: 'gt_$i')));

        adapter = ViewportSchedulerAdapter(
          playlist: playlist,
          onLoadMore: () async {},
          context: ctx,
          measureWindow: (index, horizon) {
            final end = (index + horizon + 1).clamp(0, playlist.items.length);
            return List.filled(end - index, ReadinessState.unavailable);
          },
          preloadFn: _mockPreload,
        );
        return const SizedBox();
      }));

      // Navigate to first item — starts generation 1
      adapter.onIndexChanged(0);
      await tester.pump();
      final sizeAfterStart = adapter.plannedUrls.length;

      // Navigate gradually — _completed grows within current generation
      for (int i = 1; i < 15; i++) {
        adapter.onIndexChanged(i);
      }
      await tester.pump();
      final sizeAfterSteady = adapter.plannedUrls.length;
      expect(sizeAfterSteady, greaterThan(sizeAfterStart));

      // Advance past the 30s generation expiry timer
      await tester.pump(const Duration(milliseconds: 31000));

      // Next navigation triggers generation cleanup via _needsGenerationCleanup
      adapter.onIndexChanged(16);
      await tester.pump();

      // _completed was cleared and only contains newly scheduled tasks
      final sizeAfterRollover = adapter.plannedUrls.length;
      expect(sizeAfterRollover, lessThan(sizeAfterSteady),
          reason:
              'plannedUrls should decrease after generation rollover clears _completed');

      adapter.dispose();
      playlist.dispose();
    });

    testWidgets('bounded under gradual navigation with many items',
        (tester) async {
      late ViewportSchedulerAdapter adapter;
      late PlaylistManager playlist;

      await tester.pumpWidget(_buildWrapper((ctx) {
        playlist = PlaylistManager();
        playlist.append(List.generate(50, (i) => _asset(id: 'bn_$i')));

        adapter = ViewportSchedulerAdapter(
          playlist: playlist,
          onLoadMore: () async {},
          context: ctx,
          measureWindow: (index, horizon) {
            final end = (index + horizon + 1).clamp(0, playlist.items.length);
            return List.filled(end - index, ReadinessState.unavailable);
          },
          preloadFn: _mockPreload,
        );
        return const SizedBox();
      }));

      // Navigate through all items one at a time
      for (int i = 0; i < 50; i++) {
        adapter.onIndexChanged(i);
        await tester.pump();
      }

      final urls = adapter.plannedUrls;
      expect(urls.length, lessThan(200),
          reason:
              'plannedUrls should stay bounded, not accumulate all 50 items forever');

      adapter.dispose();
      playlist.dispose();
    });

    testWidgets('memory bounded across generation rollover', (tester) async {
      late ViewportSchedulerAdapter adapter;
      late PlaylistManager playlist;

      await tester.pumpWidget(_buildWrapper((ctx) {
        playlist = PlaylistManager();
        playlist.append(List.generate(100, (i) => _asset(id: 'mb_$i')));

        adapter = ViewportSchedulerAdapter(
          playlist: playlist,
          onLoadMore: () async {},
          context: ctx,
          measureWindow: (index, horizon) {
            final end = (index + horizon + 1).clamp(0, playlist.items.length);
            return List.filled(end - index, ReadinessState.unavailable);
          },
          preloadFn: _mockPreload,
        );
        return const SizedBox();
      }));

      // Multiple iterations of steady navigation + timer rollover
      int peakSize = 0;
      for (int cycle = 0; cycle < 3; cycle++) {
        for (int i = 0; i < 20; i++) {
          adapter.onIndexChanged(i);
          await tester.pump();
        }
        // Advance past generation expiry
        await tester.pump(const Duration(milliseconds: 31000));
        final size = adapter.plannedUrls.length;
        if (size > peakSize) peakSize = size;
      }

      // Peak should be bounded (not growing cycle over cycle)
      expect(peakSize, lessThan(200),
          reason:
              'memory stays bounded across multiple generation rollovers');

      adapter.dispose();
      playlist.dispose();
    });
  });
}
