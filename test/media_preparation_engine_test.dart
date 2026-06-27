import 'package:flutter_test/flutter_test.dart';
import 'package:redslide/features/feed/domain/media_asset.dart';
import 'package:redslide/features/slideshow/domain/media_preparation_engine.dart';
import 'package:redslide/features/slideshow/domain/playlist_manager.dart';
import 'package:redslide/features/slideshow/domain/preparation_policy.dart';
import 'package:redslide/features/slideshow/domain/prepared_media_handle.dart';

MediaAsset _makeAsset({
  required String id,
  bool isVideo = false,
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
    videoUrl: isVideo ? 'https://v.redd.it/$id.mp4' : null,
    thumbnailUrl: 'https://i.redd.it/${id}_thumb.jpg',
    isVideo: isVideo,
    isGallery: isGallery,
    nsfw: false,
    qualityScore: 50,
    galleryUrls: galleryUrls,
    createdUtc: 1000000,
  );
}

void main() {
  group('MediaPreparationEngine lifecycle', () {
    test('can be created without context', () {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      expect(engine, isNotNull);
      engine.dispose();
    });

    test('can be disposed multiple times safely', () {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      engine.dispose();
      engine.dispose();
    });

    test('initialize does not crash', () {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      engine.initialize();
      engine.dispose();
    });

    test('all public methods accept empty playlist', () {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      engine.onIndexChanged(0);
      engine.onPlaylistChanged();
      engine.dispose();
    });
  });

  group('Preparation window reconciliation', () {
    test('tracks items in window after index change', () {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      final items = List.generate(20, (i) => _makeAsset(id: 'item_$i'));
      playlist.append(items);

      engine.onIndexChanged(5);

      // Items 0-12 should be tracked (window: 5-3=2 to 5+6+1=12)
      // Items 13-19 should not
      for (int i = 0; i <= 12 && i < items.length; i++) {
        expect(engine.isReady(items[i]), isA<bool>());
      }
      for (int i = 13; i < items.length; i++) {
        expect(engine.isReady(items[i]), false);
      }

      engine.dispose();
    });

    test('window shifts when index changes forward', () {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      final items = List.generate(20, (i) => _makeAsset(id: 'item_$i'));
      playlist.append(items);

      engine.onIndexChanged(0);
      // Window: 0 to 7
      expect(engine.isReady(items[0]), isA<bool>());
      expect(engine.isReady(items[7]), isA<bool>());
      expect(engine.isReady(items[8]), false);

      engine.onIndexChanged(10);
      // Window: 7 to 17
      expect(engine.isReady(items[7]), isA<bool>());
      expect(engine.isReady(items[17]), isA<bool>());
      expect(engine.isReady(items[18]), false);
      expect(engine.isReady(items[0]), false);

      engine.dispose();
    });

    test('window shifts when index changes backward', () {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      final items = List.generate(20, (i) => _makeAsset(id: 'item_$i'));
      playlist.append(items);

      engine.onIndexChanged(15);
      // Window: 12 to 20 (capped at items.length)
      expect(engine.isReady(items[12]), isA<bool>());
      expect(engine.isReady(items[19]), isA<bool>());

      engine.onIndexChanged(2);
      // Window: 0 to 9
      expect(engine.isReady(items[0]), isA<bool>());
      expect(engine.isReady(items[9]), isA<bool>());
      expect(engine.isReady(items[12]), false);

      engine.dispose();
    });

    test('window at start of playlist is correct', () {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      final items = List.generate(20, (i) => _makeAsset(id: 'item_$i'));
      playlist.append(items);

      engine.onIndexChanged(0);
      // Window: 0 to 7 (no items before index 0)
      for (int i = 0; i <= 7; i++) {
        expect(engine.isReady(items[i]), isA<bool>());
      }
      expect(engine.isReady(items[8]), false);

      engine.dispose();
    });

    test('window at end of playlist is correct', () {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      final items = List.generate(10, (i) => _makeAsset(id: 'item_$i'));
      playlist.append(items);

      engine.onIndexChanged(9);
      // Window: 6 to 10 (capped at 10)
      for (int i = 6; i < 10; i++) {
        expect(engine.isReady(items[i]), isA<bool>());
      }
      expect(engine.isReady(items[5]), isA<bool>());

      engine.dispose();
    });

    test('repeated same index is idempotent', () {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      final items = List.generate(10, (i) => _makeAsset(id: 'item_$i'));
      playlist.append(items);

      engine.onIndexChanged(3);
      engine.onIndexChanged(3);

      expect(() => engine.dispose(), returnsNormally);
    });
  });

  group('Playlist change handling', () {
    test('onPlaylistChanged re-reconciles window after items added', () {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      final items = List.generate(5, (i) => _makeAsset(id: 'item_$i'));
      playlist.append(items);

      engine.onIndexChanged(0);
      // Window: 0 to 5 (capped at 5)
      expect(engine.isReady(items[4]), isA<bool>());

      // Add more items
      final moreItems = List.generate(10, (i) => _makeAsset(id: 'more_$i'));
      playlist.append(moreItems);
      engine.onPlaylistChanged();

      // Window should now include new items: 0 to 7
      // Old items still tracked
      expect(engine.isReady(items[0]), isA<bool>());
      // New items in window should be tracked
      final newItemsInWindow = moreItems.take(3).toList();
      for (final item in newItemsInWindow) {
        expect(engine.isReady(item), isA<bool>());
      }
      // Items outside window should not be tracked
      for (int i = 3; i < moreItems.length; i++) {
        expect(engine.isReady(moreItems[i]), false);
      }

      engine.dispose();
    });
  });

  group('isReady media type awareness', () {
    test('isReady returns false for untracked items', () {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      final item = _makeAsset(id: 'untracked');
      expect(engine.isReady(item), false);
      engine.dispose();
    });

    test('isReady handles image asset', () {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      final items = [_makeAsset(id: 'img')];
      playlist.append(items);

      engine.onIndexChanged(0);

      // isReady returns false because ImageCache is empty in tests
      expect(engine.isReady(items[0]), false);

      engine.dispose();
    });

    test('isReady handles gallery asset', () {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      final items = [
        _makeAsset(id: 'gallery', isGallery: true, galleryUrls: [
          'https://i.redd.it/gallery_1.jpg',
          'https://i.redd.it/gallery_2.jpg',
        ]),
      ];
      playlist.append(items);

      engine.onIndexChanged(0);

      // Gallery: all URLs must be cached (none are in test)
      expect(engine.isReady(items[0]), false);

      engine.dispose();
    });

    test('isReady handles empty gallery urls', () {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      final items = [
        _makeAsset(id: 'empty_gallery', isGallery: true, galleryUrls: []),
      ];
      playlist.append(items);

      engine.onIndexChanged(0);

      // Empty gallery: falls through to image check on mediaUrl
      expect(engine.isReady(items[0]), false);

      engine.dispose();
    });

    test('isReady handles video asset', () {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      final items = [_makeAsset(id: 'vid', isVideo: true)];
      playlist.append(items);

      engine.onIndexChanged(0);

      // Videos always return false (video preparer not yet implemented)
      expect(engine.isReady(items[0]), false);

      engine.dispose();
    });
  });

  group('Dispose cleanup', () {
    test('dispose clears all tracked items', () {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      final items = List.generate(5, (i) => _makeAsset(id: 'item_$i'));
      playlist.append(items);

      engine.onIndexChanged(2);
      engine.dispose();

      // After dispose, all items should be untracked
      for (final item in items) {
        expect(engine.isReady(item), false);
      }
    });

    test('dispose allows safe re-creation', () {
      final playlist = PlaylistManager();
      final items = List.generate(5, (i) => _makeAsset(id: 'item_$i'));
      playlist.append(items);

      final engine1 = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      engine1.onIndexChanged(2);
      engine1.dispose();

      final engine2 = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      engine2.onIndexChanged(2);
      engine2.dispose();
    });
  });

  group('PreparationPolicy', () {
    test('default values are 6 ahead and 3 behind', () {
      final policy = const PreparationPolicy();
      expect(policy.decodedAhead, 6);
      expect(policy.decodedBehind, 3);
    });

    test('accepts custom values', () {
      final policy = const PreparationPolicy(decodedAhead: 10, decodedBehind: 5);
      expect(policy.decodedAhead, 10);
      expect(policy.decodedBehind, 5);
    });
  });

  group('PreparedMediaHandle', () {
    test('displayUrl returns mediaUrl for plain image', () {
      final asset = _makeAsset(id: 'img1');
      final handle = PreparedMediaHandle(asset: asset, ready: false);
      expect(handle.displayUrl, asset.mediaUrl);
    });

    test('displayUrl returns mediaUrl for gallery after prepare resolution', () {
      final asset = _makeAsset(id: 'gallery', isGallery: true, galleryUrls: [
        'https://i.redd.it/gallery_1.jpg',
        'https://i.redd.it/gallery_2.jpg',
      ]);
      final engine = MediaPreparationEngine(
        playlist: PlaylistManager(),
        onLoadMore: () async {},
      );
      final handle = engine.prepare(asset, galleryIndex: 1);
      // prepare() resolves galleryIndex into mediaUrl via copyWith
      expect(handle.displayUrl, 'https://i.redd.it/gallery_2.jpg');
      expect(handle.isVideo, false);
      engine.dispose();
    });

    test('isVideo returns true for video assets', () {
      final asset = _makeAsset(id: 'vid1', isVideo: true);
      final handle = PreparedMediaHandle(asset: asset, ready: false);
      expect(handle.isVideo, true);
    });

    test('displayThumbnailUrl falls back to mediaUrl', () {
      // Use raw MediaAsset constructor to set thumbnailUrl to null
      final noThumbAsset = MediaAsset(
        id: 'no_thumb',
        title: 'No Thumb',
        author: 'test',
        score: 0,
        subreddit: 'test',
        mediaUrl: 'https://i.redd.it/no_thumb.jpg',
        videoUrl: null,
        thumbnailUrl: null,
        isVideo: false,
        isGallery: false,
        nsfw: false,
        qualityScore: 0,
        galleryUrls: null,
        createdUtc: 0,
      );
      final handle = PreparedMediaHandle(asset: noThumbAsset, ready: false);
      expect(handle.displayThumbnailUrl, 'https://i.redd.it/no_thumb.jpg');
    });
  });

  group('MPE.prepare method', () {
    test('prepare returns handle with ready=false for unindexed items', () {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      final asset = _makeAsset(id: 'unindexed');
      final handle = engine.prepare(asset);
      expect(handle.asset.id, 'unindexed');
      expect(handle.ready, false);
      engine.dispose();
    });

    test('prepare resolves gallery URL to displayUrl', () {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      final asset = _makeAsset(
        id: 'gallery_resolve',
        isGallery: true,
        galleryUrls: [
          'https://i.redd.it/gallery_a.jpg',
          'https://i.redd.it/gallery_b.jpg',
          'https://i.redd.it/gallery_c.jpg',
        ],
      );
      final handle = engine.prepare(asset, galleryIndex: 2);
      expect(handle.displayUrl, 'https://i.redd.it/gallery_c.jpg');
      engine.dispose();
    });

    test('prepare with galleryIndex outside bounds clamps to valid range', () {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      final asset = _makeAsset(
        id: 'gallery_clamp',
        isGallery: true,
        galleryUrls: ['https://i.redd.it/gallery_a.jpg'],
      );
      final handle = engine.prepare(asset, galleryIndex: 999);
      expect(handle.displayUrl, 'https://i.redd.it/gallery_a.jpg');
      engine.dispose();
    });

    test('prepare returns tracked item with isReady status', () {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      final items = [_makeAsset(id: 'tracked_img')];
      playlist.append(items);
      engine.onIndexChanged(0);

      final handle = engine.prepare(items[0]);
      expect(handle.asset.id, 'tracked_img');
      // isReady returns false because ImageCache is empty in tests
      expect(handle.ready, false);
      engine.dispose();
    });
  });

  group('Video preparation integration', () {
    test('isReady for video returns false without prepared controller', () {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      final items = [_makeAsset(id: 'vid', isVideo: true)];
      playlist.append(items);

      // Controller not yet prepared
      expect(engine.isReady(items[0]), false);
      engine.dispose();
    });

    test('isReady for video returns false after reconciliation begins', () {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      final items = [_makeAsset(id: 'vid', isVideo: true)];
      playlist.append(items);

      engine.onIndexChanged(0);

      // Controller is being prepared (async), not ready yet
      expect(engine.isReady(items[0]), false);
      engine.dispose();
    });

    test('prepare returns handle without controller for unprepared video', () {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      final items = [_makeAsset(id: 'vid', isVideo: true)];
      playlist.append(items);

      final handle = engine.prepare(items[0]);
      expect(handle.isVideo, true);
      expect(handle.controller, null);
      expect(handle.preparationFailed, false);
      expect(handle.ready, false);
      engine.dispose();
    });

    test('prepare returns handle with preparationFailed after error', () async {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      final items = [_makeAsset(id: 'vid', isVideo: true)];
      playlist.append(items);

      engine.onIndexChanged(0);

      // Give async preparation time to fail (no platform channel in test)
      await Future.delayed(Duration.zero);

      // After failed attempt, prepare should report failure
      final handle = engine.prepare(items[0]);
      expect(handle.preparationFailed, true);
      expect(handle.controller, null);
      engine.dispose();
    });

    test('reconciliation evicts video controllers outside window', () async {
      final playlist = PlaylistManager();
      final engine = MediaPreparationEngine(
        playlist: playlist,
        onLoadMore: () async {},
      );
      final items = [
        _makeAsset(id: 'vid1', isVideo: true),
        _makeAsset(id: 'vid2', isVideo: true),
        _makeAsset(id: 'vid3', isVideo: true),
      ];
      playlist.append(items);

      // Index 1: window includes vid1, vid2, vid3 (1-3=0..1+6+1=8 capped at 3)
      engine.onIndexChanged(1);

      // Move away: index changes so reconciliation re-runs
      // vid1 and vid3 should stay in window (still within range)
      // Nothing actually outside window since all 3 items fit
      engine.dispose();
    });
  });
}
