import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart' as vpi;
import 'package:redslide/features/slideshow/presentation/widgets/video_viewer.dart';
import 'package:redslide/features/slideshow/domain/prepared_media_handle.dart';
import 'package:redslide/features/feed/domain/media_asset.dart';

/// Minimal fake platform so [VideoPlayerController] methods do not throw.
class _FakePlatform extends vpi.VideoPlayerPlatform {
  int _nextPlayerId = 0;

  @override
  Future<void> init() async {}

  @override
  Future<int?> create(vpi.DataSource dataSource) async => _nextPlayerId++;

  @override
  Future<int?> createWithOptions(vpi.VideoCreationOptions options) async =>
      _nextPlayerId++;

  /// Returns a stream that emits one initialised event then stays open.
  @override
  Stream<vpi.VideoEvent> videoEventsFor(int playerId) {
    return Stream<vpi.VideoEvent>.fromFuture(
      Future<vpi.VideoEvent>.value(
        vpi.VideoEvent(
          eventType: vpi.VideoEventType.initialized,
          duration: const Duration(seconds: 30),
          size: const Size(1920, 1080),
          rotationCorrection: 0,
        ),
      ),
    );
  }

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Future<void> dispose(int playerId) async {}

  @override
  Widget buildViewWithOptions(vpi.VideoViewOptions options) =>
      const SizedBox();
}

MediaAsset _makeAsset(String id) {
  return MediaAsset(
    id: id,
    title: 'Test $id',
    author: 'test',
    score: 100,
    subreddit: 'test',
    mediaUrl: 'https://i.redd.it/$id.jpg',
    videoUrl: 'https://v.redd.it/$id.mp4',
    thumbnailUrl: 'https://i.redd.it/${id}_thumb.jpg',
    isVideo: true,
    isGallery: false,
    nsfw: false,
    qualityScore: 50,
    galleryUrls: null,
    createdUtc: 1000000,
  );
}

PreparedMediaHandle _makeHandle(String id, VideoPlayerController? ctrl) {
  return PreparedMediaHandle(
    asset: _makeAsset(id),
    state: ctrl != null ? MediaState.ready : MediaState.preparing,
    controller: ctrl,
  );
}

void main() {
  setUp(() {
    vpi.VideoPlayerPlatform.instance = _FakePlatform();
  });

  group('VideoViewer smoke tests', () {
    testWidgets('renders with null controller', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VideoViewer(handle: _makeHandle('null', null), muted: true),
        ),
      );
      await tester.pump();
      expect(find.byType(VideoViewer), findsOneWidget);
    });

    testWidgets('renders with a controller', (WidgetTester tester) async {
      final ctrl = VideoPlayerController.network('https://v.redd.it/smoke.mp4');
      await tester.runAsync(() => ctrl.initialize());

      await tester.pumpWidget(
        MaterialApp(
          home: VideoViewer(handle: _makeHandle('smoke', ctrl), muted: true),
        ),
      );
      await tester.pump();

      // Advance past first frame so _firstFrameRendered guard lifts
      ctrl.value = ctrl.value.copyWith(position: const Duration(milliseconds: 1));
      await tester.pump();

      expect(find.byType(VideoViewer), findsOneWidget);
      await tester.runAsync(() => ctrl.dispose());
    });

    testWidgets('dispose does not throw', (WidgetTester tester) async {
      final ctrl = VideoPlayerController.network('https://v.redd.it/dispose.mp4');
      await tester.runAsync(() => ctrl.initialize());

      await tester.pumpWidget(
        MaterialApp(
          home: VideoViewer(handle: _makeHandle('dispose', ctrl), muted: true),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();
      await tester.runAsync(() => ctrl.dispose());
    });
  });

  group('VideoViewer completion callback', () {
    testWidgets('onVideoCompleted fires when position reaches duration',
        (WidgetTester tester) async {
      final ctrl =
          VideoPlayerController.network('https://v.redd.it/complete.mp4');
      await tester.runAsync(() => ctrl.initialize());

      int completions = 0;
      String? completedUrl;

      await tester.pumpWidget(
        MaterialApp(
          home: VideoViewer(
            handle: _makeHandle('complete', ctrl),
            muted: true,
            onVideoCompleted: (url) {
              completions++;
              completedUrl = url;
            },
          ),
        ),
      );
      await tester.pump();

      // Advance past first frame so _onVideoUpdate processes subsequent events
      ctrl.value = ctrl.value.copyWith(position: const Duration(milliseconds: 1));
      await tester.pump();

      ctrl.value = ctrl.value.copyWith(
        position: const Duration(seconds: 30),
        duration: const Duration(seconds: 30),
      );
      await tester.pump();

      expect(completions, 1,
          reason: 'completion fires when position >= duration');
      expect(completedUrl, 'https://v.redd.it/complete.mp4');
      await tester.runAsync(() => ctrl.dispose());
    });

    testWidgets('onVideoCompleted fires only once',
        (WidgetTester tester) async {
      final ctrl =
          VideoPlayerController.network('https://v.redd.it/once.mp4');
      await tester.runAsync(() => ctrl.initialize());

      int completions = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: VideoViewer(
            handle: _makeHandle('once', ctrl),
            muted: true,
            onVideoCompleted: (_) => completions++,
          ),
        ),
      );
      await tester.pump();

      ctrl.value = ctrl.value.copyWith(position: const Duration(milliseconds: 1));
      await tester.pump();

      ctrl.value = ctrl.value.copyWith(position: const Duration(seconds: 30));
      await tester.pump();
      expect(completions, 1, reason: 'first completion');

      ctrl.value = ctrl.value.copyWith(
        position: const Duration(seconds: 30, milliseconds: 100),
      );
      await tester.pump();
      expect(completions, 1, reason: 'completion must not fire again');
      await tester.runAsync(() => ctrl.dispose());
    });
  });

  group('VideoViewer state machine edge cases', () {
    testWidgets('completion guard resets on controller replacement',
        (WidgetTester tester) async {
      final ctrl1 =
          VideoPlayerController.network('https://v.redd.it/r1.mp4');
      await tester.runAsync(() => ctrl1.initialize());
      int completions = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: VideoViewer(
            handle: _makeHandle('r1', ctrl1),
            muted: true,
            onVideoCompleted: (_) => completions++,
          ),
        ),
      );
      await tester.pump();
      ctrl1.value = ctrl1.value.copyWith(position: const Duration(milliseconds: 1));
      await tester.pump();
      ctrl1.value =
          ctrl1.value.copyWith(position: const Duration(seconds: 30));
      await tester.pump();
      expect(completions, 1, reason: 'first completion');

      final ctrl2 =
          VideoPlayerController.network('https://v.redd.it/r2.mp4');
      await tester.runAsync(() => ctrl2.initialize());

      await tester.pumpWidget(
        MaterialApp(
          home: VideoViewer(
            handle: _makeHandle('r2', ctrl2),
            muted: true,
            onVideoCompleted: (_) => completions++,
          ),
        ),
      );
      await tester.pump();
      ctrl2.value = ctrl2.value.copyWith(position: const Duration(milliseconds: 1));
      await tester.pump();
      ctrl2.value =
          ctrl2.value.copyWith(position: const Duration(seconds: 30));
      await tester.pump();
      expect(completions, 2,
          reason: 'completion fires again after controller replacement');

      await tester.runAsync(() => ctrl1.dispose());
      await tester.runAsync(() => ctrl2.dispose());
    });

    testWidgets('user pause works', (WidgetTester tester) async {
      final ctrl = VideoPlayerController.network('https://v.redd.it/pause.mp4');
      await tester.runAsync(() => ctrl.initialize());

      await tester.pumpWidget(
        MaterialApp(
          home: VideoViewer(
            handle: _makeHandle('pause', ctrl),
            muted: true,
          ),
        ),
      );
      await tester.pump();

      // Advance past first frame so GestureDetector is rendered
      ctrl.value = ctrl.value.copyWith(position: const Duration(milliseconds: 1));
      await tester.pump();

      await tester.tap(find.byType(GestureDetector));
      await tester.pump();

      expect(ctrl.value.isPlaying, false, reason: 'paused after tap');
      await tester.runAsync(() => ctrl.dispose());
    });

    testWidgets('replay works after completion',
        (WidgetTester tester) async {
      final ctrl = VideoPlayerController.network('https://v.redd.it/replay.mp4');
      await tester.runAsync(() => ctrl.initialize());

      int completions = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: VideoViewer(
            handle: _makeHandle('replay', ctrl),
            muted: true,
            onVideoCompleted: (_) => completions++,
          ),
        ),
      );
      await tester.pump();

      // Advance past first frame so GestureDetector is rendered
      ctrl.value = ctrl.value.copyWith(position: const Duration(milliseconds: 1));
      await tester.pump();

      // Now complete the video
      ctrl.value = ctrl.value.copyWith(position: const Duration(seconds: 30));
      await tester.pump();
      expect(completions, 1, reason: 'first completion');

      await tester.tap(find.byType(GestureDetector));
      await tester.pump();

      expect(ctrl.value.isPlaying, true, reason: 'playing after replay tap');
      await tester.runAsync(() => ctrl.dispose());
    });
  });
}
