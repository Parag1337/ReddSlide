import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:redslide/core/display_quality/display_quality_mode.dart';
import 'package:redslide/features/feed/domain/media_asset.dart';
import 'package:redslide/features/slideshow/domain/playlist_manager.dart';
import 'package:redslide/features/slideshow/domain/readiness_state.dart';
import 'package:redslide/features/slideshow/domain/slide_profiler.dart';
import 'package:redslide/features/slideshow/domain/viewport_scheduler_adapter.dart';

MediaAsset _asset({
  required String id,
  bool isGallery = false,
  List<String>? galleryUrls,
}) {
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
    isGallery: isGallery,
    nsfw: false,
    qualityScore: 50,
    galleryUrls: galleryUrls,
    createdUtc: 1000000,
  );
}

Future<void> _mockPreload(String url, BuildContext context) async {}

int _readinessScore(List<ReadinessState> states) {
  if (states.isEmpty) return 0;
  final ready = states.where((s) => s == ReadinessState.ready).length;
  return ready * 100 ~/ states.length;
}

void main() {
  group('QA: Normal Slideshow — ViewportScheduler', () {
    testWidgets('50 navigation steps, 200 items', (tester) async {
      SlideProfiler.reset();
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (ctx) {
          final playlist = PlaylistManager();
          playlist.append(List.generate(200, (i) => _asset(id: 'n_$i')));

          final adapter = ViewportSchedulerAdapter(
            playlist: playlist,
            onLoadMore: () async {},
            context: ctx,
            measureWindow: (index, horizon) {
              final end = (index + horizon + 1).clamp(0, playlist.items.length);
              return List.filled(end - index, ReadinessState.unavailable);
            },
            preloadFn: _mockPreload,
          );

          for (int i = 0; i < 50; i++) adapter.onIndexChanged(i);

          final json = SlideProfiler.dumpJson();
          final s = json['scheduler'] as Map;
          print('══ Normal Slideshow (Viewport) ══');
          print('  NeedCount:    ${s['needCount']}');
          print('  Generation:   ${s['generation']}');
          print('  Pending:      ${s['pendingTasks']}');
          print('  Completed:    ${s['completedTasks']}');
          print('  Cancelled:    ${s['cancelledTasks']}');
          final timings = s['timing'] as Map;
          print('  DemandCalc:   ${timings['demandCalcAvgUs']}us');
          print('  Plan:         ${timings['planAvgUs']}us');
          print('  Enqueue:      ${timings['enqueueAvgUs']}us');
          print('  PickTask:     ${timings['pickTaskAvgUs']}us');
          final rings = s['rings'] as Map;
          print('  Rings:        imm=${rings['immediate']} crit=${rings['critical']} near=${rings['near']} bg=${rings['background']}');
          print('  Readiness:    ${s['readinessScore']}%');
          print('  Agreement:    ${s['agreement']}%');

          adapter.dispose();
          playlist.dispose();
          return const SizedBox();
        }),
      ));

      final json = SlideProfiler.dumpJson();
      final s = json['scheduler'] as Map;
      expect((s['pendingTasks'] as num), greaterThanOrEqualTo(0));
    });
  });

  group('QA: Galleries — ViewportScheduler', () {
    testWidgets('1/8 → 8/8 → next → prev', (tester) async {
      SlideProfiler.reset();
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (ctx) {
          final playlist = PlaylistManager();
          playlist.append([
            _asset(
              id: 'gal',
              isGallery: true,
              galleryUrls: List.generate(8, (i) => 'https://i.redd.it/gal_$i.jpg'),
            ),
            _asset(id: 'next_post'),
          ]);

          final adapter = ViewportSchedulerAdapter(
            playlist: playlist,
            onLoadMore: () async {},
            context: ctx,
            measureWindow: (index, horizon) {
              final end = (index + horizon + 1).clamp(0, playlist.items.length);
              return List.filled(end - index, ReadinessState.unavailable);
            },
            preloadFn: _mockPreload,
          );

          for (int g = 0; g < 8; g++) adapter.onIndexChanged(0, galleryIndex: g);
          adapter.onIndexChanged(1); // next
          adapter.onIndexChanged(0); // prev

          final json = SlideProfiler.dumpJson();
          print('══ Gallery Navigation (Viewport) ══');
          print('  ${json['scheduler']}');

          adapter.dispose();
          playlist.dispose();
          return const SizedBox();
        }),
      ));
    });
  });

  group('QA: Rapid Swiping — ViewportScheduler', () {
    testWidgets('100 rapid steps, 200 items', (tester) async {
      SlideProfiler.reset();
      final sw = Stopwatch()..start();
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (ctx) {
          final playlist = PlaylistManager();
          playlist.append(List.generate(200, (i) => _asset(id: 'rs_$i')));

          final adapter = ViewportSchedulerAdapter(
            playlist: playlist,
            onLoadMore: () async {},
            context: ctx,
            measureWindow: (index, horizon) {
              final end = (index + horizon + 1).clamp(0, playlist.items.length);
              return List.filled(end - index, ReadinessState.unavailable);
            },
            preloadFn: _mockPreload,
          );

          for (int i = 0; i < 100; i++) adapter.onIndexChanged(i);

          adapter.dispose();
          playlist.dispose();
          return const SizedBox();
        }),
      ));
      sw.stop();
      print('══ Rapid Swiping: 100 navs in ${sw.elapsedMilliseconds}ms ══');
    });
  });

  group('QA: Large Jumps — ViewportScheduler', () {
    testWidgets('10→500→25→800', (tester) async {
      SlideProfiler.reset();
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (ctx) {
          final playlist = PlaylistManager();
          playlist.append(List.generate(1000, (i) => _asset(id: 'lj_$i')));

          final adapter = ViewportSchedulerAdapter(
            playlist: playlist,
            onLoadMore: () async {},
            context: ctx,
            measureWindow: (index, horizon) {
              final end = (index + horizon + 1).clamp(0, playlist.items.length);
              return List.filled(end - index, ReadinessState.unavailable);
            },
            preloadFn: _mockPreload,
          );

          adapter.onIndexChanged(10);
          adapter.onIndexChanged(500);
          adapter.onIndexChanged(25);
          adapter.onIndexChanged(800);

          final json = SlideProfiler.dumpJson();
          print('══ Large Jumps (Viewport) ══');
          print('  ${json['scheduler']}');

          adapter.dispose();
          playlist.dispose();
          return const SizedBox();
        }),
      ));
    });
  });

  group('QA: Failure — ViewportScheduler', () {
    testWidgets('measureWindow error → hasFailed', (tester) async {
      SlideProfiler.reset();
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (ctx) {
          final playlist = PlaylistManager();
          playlist.append(List.generate(20, (i) => _asset(id: 'fl_$i')));

          int calls = 0;
          final adapter = ViewportSchedulerAdapter(
            playlist: playlist,
            onLoadMore: () async {},
            context: ctx,
            measureWindow: (index, horizon) {
              calls++;
              if (calls >= 3) throw Exception('simulated failure');
              final end = (index + horizon + 1).clamp(0, playlist.items.length);
              return List.filled(end - index, ReadinessState.unavailable);
            },
            preloadFn: _mockPreload,
          );

          adapter.onIndexChanged(0);
          adapter.onIndexChanged(5);
          adapter.onIndexChanged(10); // this one will trigger failure
          adapter.onIndexChanged(15); // should be swallowed (failed state)

          print('══ Failure Analysis (Viewport) ══');
          print('  hasFailed=${adapter.hasFailed}  calls=$calls');

          adapter.dispose();
          playlist.dispose();
          return const SizedBox();
        }),
      ));
    });
  });

  group('QA: Scaled — ViewportScheduler', () {
    testWidgets('500 items, varied readiness, 200 navs', (tester) async {
      SlideProfiler.reset();
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (ctx) {
          final playlist = PlaylistManager();
          playlist.append(List.generate(500, (i) => _asset(id: 'sc_$i')));

          final rng = Random(42);
          final adapter = ViewportSchedulerAdapter(
            playlist: playlist,
            onLoadMore: () async {},
            context: ctx,
            measureWindow: (index, horizon) {
              final end = (index + horizon + 1).clamp(0, playlist.items.length);
              return List.generate(end - index, (_) {
                final v = rng.nextDouble();
                if (v < 0.6) return ReadinessState.unavailable;
                if (v < 0.85) return ReadinessState.likelyReady;
                if (v < 0.95) return ReadinessState.ready;
                return ReadinessState.unavailable;
              });
            },
            preloadFn: _mockPreload,
          );

          for (int i = 0; i < 200; i++) {
            final idx = rng.nextInt(500);
            adapter.onIndexChanged(idx);
          }

          final report = SlideProfiler.dumpReport();
          print('══ Scaled Benchmark (Viewport, 500 items, 200 navs) ══');
          print(report);

          adapter.dispose();
          playlist.dispose();
          return const SizedBox();
        }),
      ));
    });
  });
}
