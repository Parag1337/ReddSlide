import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:redslide/features/feed/domain/media_asset.dart';
import 'package:redslide/features/slideshow/domain/playlist_manager.dart';
import 'package:redslide/features/slideshow/domain/readiness_state.dart';
import 'package:redslide/features/slideshow/domain/viewport_scheduler_adapter.dart';

MediaAsset _asset({
  required String id,
  bool isGallery = false,
  List<String>? galleryUrls,
  String? mediaUrl,
}) {
  return MediaAsset(
    id: id,
    title: 'Test $id',
    author: 'test_author',
    score: 100,
    subreddit: 'test',
    mediaUrl: mediaUrl ?? 'https://i.redd.it/$id.jpg',
    videoUrl: null,
    thumbnailUrl: null,
    isVideo: false,
    isGallery: isGallery,
    nsfw: false,
    qualityScore: 50,
    galleryUrls: galleryUrls,
    createdUtc: 1000000,
  );
}

Future<void> _mockPreload(String url, BuildContext context) async {}

void main() {
  group('ViewportSchedulerAdapter — navigation basics', () {
    testWidgets('navigating to first item produces planned URLs',
        (tester) async {
      final playlist = PlaylistManager();
      playlist.append(List.generate(20, (i) => _asset(id: 'item_$i')));

      final started = <String>[];
      final ready = <String>[];
      final failed = <String>[];

      late ViewportSchedulerAdapter adapter;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              adapter = ViewportSchedulerAdapter(
                playlist: playlist,
                onLoadMore: () async {},
                context: context,
                measureWindow: (index, horizon) {
                  final end =
                      (index + horizon + 1).clamp(0, playlist.items.length);
                  return List.filled(end - index, ReadinessState.unavailable);
                },
                preloadFn: _mockPreload,
              );

              adapter.onUrlStarted = (url) => started.add(url);
              adapter.onUrlReady = (url) => ready.add(url);
              adapter.onUrlFailed = (url) => failed.add(url);

              adapter.onIndexChanged(0);

              expect(adapter.plannedUrls, isNotEmpty,
                  reason: 'planned URLs after navigation');
              expect(adapter.isIdle, isFalse,
                  reason: 'not idle with active preloads');
              expect(adapter.hasFailed, isFalse, reason: 'not failed');
              expect(started, isNotEmpty, reason: 'preload started');

              return const SizedBox();
            },
          ),
        ),
      );

      adapter.dispose();
      playlist.dispose();
    });
  });

  group('ViewportSchedulerAdapter — generation policy', () {
    testWidgets('major jump does not cause failure', (tester) async {
      final playlist = PlaylistManager();
      playlist.append(List.generate(100, (i) => _asset(id: 'item_$i')));

      late ViewportSchedulerAdapter adapter;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              adapter = ViewportSchedulerAdapter(
                playlist: playlist,
                onLoadMore: () async {},
                context: context,
                measureWindow: (index, horizon) {
                  final end =
                      (index + horizon + 1).clamp(0, playlist.items.length);
                  return List.filled(end - index, ReadinessState.unavailable);
                },
                preloadFn: _mockPreload,
              );

              adapter.onIndexChanged(0);
              expect(adapter.hasFailed, isFalse,
                  reason: 'not failed after first nav');

              adapter.onIndexChanged(50);
              expect(adapter.hasFailed, isFalse,
                  reason: 'not failed after major jump');
              expect(adapter.plannedUrls, isNotEmpty,
                  reason: 'URLs planned after jump');

              return const SizedBox();
            },
          ),
        ),
      );

      adapter.dispose();
      playlist.dispose();
    });

    testWidgets('small step does not crash', (tester) async {
      final playlist = PlaylistManager();
      playlist.append(List.generate(100, (i) => _asset(id: 'item_$i')));

      late ViewportSchedulerAdapter adapter;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              adapter = ViewportSchedulerAdapter(
                playlist: playlist,
                onLoadMore: () async {},
                context: context,
                measureWindow: (index, horizon) {
                  final end =
                      (index + horizon + 1).clamp(0, playlist.items.length);
                  return List.filled(end - index, ReadinessState.unavailable);
                },
                preloadFn: _mockPreload,
              );

              adapter.onIndexChanged(10);
              adapter.onIndexChanged(11);
              adapter.onIndexChanged(12);

              expect(adapter.hasFailed, isFalse,
                  reason: 'small steps do not cause failure');
              expect(adapter.plannedUrls, isNotEmpty,
                  reason: 'URLs still planned after small steps');

              return const SizedBox();
            },
          ),
        ),
      );

      adapter.dispose();
      playlist.dispose();
    });
  });

  group('ViewportSchedulerAdapter — galleryIndex', () {
    testWidgets('galleryIndex affects planned URLs', (tester) async {
      final playlist = PlaylistManager();
      playlist.append([
        _asset(
          id: 'gal',
          isGallery: true,
          galleryUrls:
              List.generate(8, (i) => 'https://i.redd.it/gal_$i.jpg'),
        ),
        _asset(id: 'a'),
        _asset(id: 'b'),
      ]);

      late ViewportSchedulerAdapter adapter;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              adapter = ViewportSchedulerAdapter(
                playlist: playlist,
                onLoadMore: () async {},
                context: context,
                measureWindow: (index, horizon) {
                  final end =
                      (index + horizon + 1).clamp(0, playlist.items.length);
                  return List.filled(end - index, ReadinessState.unavailable);
                },
                preloadFn: _mockPreload,
              );

              adapter.onIndexChanged(0, galleryIndex: 3);
              final urls = adapter.plannedUrls;

              expect(urls.any((u) => u == 'https://i.redd.it/gal_4.jpg'),
                  isTrue,
                  reason: 'gallery position 4 planned');
              expect(urls.any((u) => u == 'https://i.redd.it/gal_5.jpg'),
                  isTrue,
                  reason: 'gallery position 5 planned');

              return const SizedBox();
            },
          ),
        ),
      );

      adapter.dispose();
      playlist.dispose();
    });
  });

  group('ViewportSchedulerAdapter — fallback', () {
    testWidgets('hasFailed after measureWindow error', (tester) async {
      final playlist = PlaylistManager();
      playlist.append(List.generate(10, (i) => _asset(id: 'item_$i')));

      int callCount = 0;

      late ViewportSchedulerAdapter adapter;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              adapter = ViewportSchedulerAdapter(
                playlist: playlist,
                onLoadMore: () async {},
                context: context,
                measureWindow: (index, horizon) {
                  callCount++;
                  if (callCount >= 2) throw Exception('measureWindow failed');
                  final end =
                      (index + horizon + 1).clamp(0, playlist.items.length);
                  return List.filled(end - index, ReadinessState.unavailable);
                },
                preloadFn: _mockPreload,
              );

              adapter.onIndexChanged(0);
              expect(adapter.hasFailed, isFalse);

              adapter.onIndexChanged(1);
              expect(adapter.hasFailed, isTrue,
                  reason: 'scheduler failed after measureWindow error');

              return const SizedBox();
            },
          ),
        ),
      );

      adapter.dispose();
      playlist.dispose();
    });
  });

  group('ViewportSchedulerAdapter — onPlaylistReplaced', () {
    testWidgets('replace resets and replans', (tester) async {
      final playlist = PlaylistManager();
      playlist.append(List.generate(10, (i) => _asset(id: 'item_$i')));

      late ViewportSchedulerAdapter adapter;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              adapter = ViewportSchedulerAdapter(
                playlist: playlist,
                onLoadMore: () async {},
                context: context,
                measureWindow: (index, horizon) {
                  final end =
                      (index + horizon + 1).clamp(0, playlist.items.length);
                  return List.filled(end - index, ReadinessState.unavailable);
                },
                preloadFn: _mockPreload,
              );

              adapter.onIndexChanged(0);
              adapter.onPlaylistReplaced();
              adapter.onIndexChanged(0);

              expect(adapter.hasFailed, isFalse,
                  reason: 'not failed after playlist replace');
              expect(adapter.plannedUrls, isNotEmpty,
                  reason: 'URLs planned after replace');

              return const SizedBox();
            },
          ),
        ),
      );

      adapter.dispose();
      playlist.dispose();
    });
  });
}
