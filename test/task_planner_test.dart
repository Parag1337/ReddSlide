import 'package:flutter_test/flutter_test.dart';
import 'package:redslide/features/feed/domain/media_asset.dart';
import 'package:redslide/features/slideshow/domain/scheduler_task.dart';
import 'package:redslide/features/slideshow/domain/task_planner.dart';

MediaAsset _makeAsset({
  required String id,
  bool isVideo = false,
  bool isGallery = false,
  List<String>? galleryUrls,
  String? mediaUrl,
  String? videoUrl,
  String? thumbnailUrl,
}) {
  return MediaAsset(
    id: id,
    title: 'Test $id',
    author: 'test_author',
    score: 100,
    subreddit: 'test',
    mediaUrl: mediaUrl ?? 'https://i.redd.it/$id.jpg',
    videoUrl: videoUrl ?? (isVideo ? 'https://v.redd.it/$id.mp4' : null),
    thumbnailUrl: thumbnailUrl ?? (isVideo ? 'https://i.redd.it/${id}_thumb.jpg' : null),
    isVideo: isVideo,
    isGallery: isGallery,
    nsfw: false,
    qualityScore: 50,
    galleryUrls: galleryUrls,
    createdUtc: 1000000,
  );
}

void main() {
  final planner = const TaskPlanner();

  group('edge cases', () {
    test('empty playlist returns empty list', () {
      final result = planner.plan(
        items: [],
        currentIndex: 0,
        horizon: 10,
        needCount: 10,
        generation: 1,
      );
      expect(result, isEmpty);
    });

    test('index beyond playlist returns empty', () {
      final items = [_makeAsset(id: 'a')];
      final result = planner.plan(
        items: items,
        currentIndex: 5,
        horizon: 10,
        needCount: 10,
        generation: 1,
      );
      expect(result, isEmpty);
    });

    test('needCount zero returns empty', () {
      final items = List.generate(10, (i) => _makeAsset(id: 'item_$i'));
      final result = planner.plan(
        items: items,
        currentIndex: 0,
        horizon: 10,
        needCount: 0,
        generation: 1,
      );
      expect(result, isEmpty);
    });

    test('needCount negative returns empty', () {
      final items = List.generate(10, (i) => _makeAsset(id: 'item_$i'));
      final result = planner.plan(
        items: items,
        currentIndex: 0,
        horizon: 10,
        needCount: -1,
        generation: 1,
      );
      expect(result, isEmpty);
    });

    test('horizon of zero returns only current position', () {
      final items = List.generate(5, (i) => _makeAsset(id: 'item_$i'));
      final result = planner.plan(
        items: items,
        currentIndex: 2,
        horizon: 0,
        needCount: 10,
        generation: 1,
      );
      // horizon=0 means indices [2, 2+0] = just index 2
      expect(result.length, 1);
      expect(result[0].index, 2);
    });
  });

  group('standard planning', () {
    test('single item returns one task', () {
      final items = [_makeAsset(id: 'a')];
      final result = planner.plan(
        items: items,
        currentIndex: 0,
        horizon: 5,
        needCount: 10,
        generation: 1,
      );
      expect(result.length, 1);
      expect(result[0].assetId, 'a');
      expect(result[0].url, 'https://i.redd.it/a.jpg');
      expect(result[0].mediaType, MediaTaskType.image);
      expect(result[0].generation, 1);
    });

    test('respects horizon', () {
      final items = List.generate(20, (i) => _makeAsset(id: 'item_$i'));
      final result = planner.plan(
        items: items,
        currentIndex: 5,
        horizon: 3,
        needCount: 100,
        generation: 1,
      );
      // horizon=3 means indices 5,6,7,8 (4 positions)
      expect(result.length, 4);
      expect(result[0].index, 5);
      expect(result[1].index, 6);
      expect(result[2].index, 7);
      expect(result[3].index, 8);
    });

    test('respects needCount', () {
      final items = List.generate(20, (i) => _makeAsset(id: 'item_$i'));
      final result = planner.plan(
        items: items,
        currentIndex: 0,
        horizon: 10,
        needCount: 3,
        generation: 1,
      );
      expect(result.length, 3);
    });

    test('generation is propagated to all tasks', () {
      final items = List.generate(5, (i) => _makeAsset(id: 'item_$i'));
      final result = planner.plan(
        items: items,
        currentIndex: 0,
        horizon: 5,
        needCount: 10,
        generation: 42,
      );
      for (final task in result) {
        expect(task.generation, 42);
      }
    });

    test('tasks ordered by position', () {
      final items = List.generate(10, (i) => _makeAsset(id: 'item_$i'));
      final result = planner.plan(
        items: items,
        currentIndex: 3,
        horizon: 5,
        needCount: 10,
        generation: 1,
      );
      expect(result.length, 6); // indices 3..8
      for (int i = 0; i < result.length; i++) {
        expect(result[i].index, 3 + i);
      }
    });
  });

  group('playlist boundaries', () {
    test('beginning of playlist starts at index 0', () {
      final items = List.generate(10, (i) => _makeAsset(id: 'item_$i'));
      final result = planner.plan(
        items: items,
        currentIndex: 0,
        horizon: 5,
        needCount: 10,
        generation: 1,
      );
      expect(result.length, 6); // indices 0..5
      expect(result[0].index, 0);
    });

    test('end of playlist respects item count', () {
      final items = List.generate(5, (i) => _makeAsset(id: 'item_$i'));
      final result = planner.plan(
        items: items,
        currentIndex: 3,
        horizon: 10,
        needCount: 10,
        generation: 1,
      );
      expect(result.length, 2); // indices 3, 4 only
      expect(result[0].index, 3);
      expect(result[1].index, 4);
    });

    test('large jump into playlist', () {
      final items = List.generate(100, (i) => _makeAsset(id: 'item_$i'));
      final result = planner.plan(
        items: items,
        currentIndex: 50,
        horizon: 5,
        needCount: 10,
        generation: 1,
      );
      expect(result.length, 6); // indices 50..55
      expect(result[0].index, 50);
      expect(result[1].index, 51);
    });
  });

  group('galleries', () {
    test('remaining gallery images come before next post', () {
      final items = [
        _makeAsset(
          id: 'gal',
          isGallery: true,
          galleryUrls: [
            'https://i.redd.it/gal_0.jpg',
            'https://i.redd.it/gal_1.jpg',
            'https://i.redd.it/gal_2.jpg',
            'https://i.redd.it/gal_3.jpg',
          ],
        ),
        _makeAsset(id: 'next'),
      ];
      final result = planner.plan(
        items: items,
        currentIndex: 0,
        horizon: 3,
        needCount: 10,
        generation: 1,
        galleryIndex: 1,
      );
      // Remaining gallery images: gal_2, gal_3 come first
      // Then next post (index 1)
      expect(result.length, 3);
      expect(result[0].url, 'https://i.redd.it/gal_2.jpg');
      expect(result[0].galleryPosition, 2);
      expect(result[0].galleryLength, 4);
      expect(result[1].url, 'https://i.redd.it/gal_3.jpg');
      expect(result[1].galleryPosition, 3);
      expect(result[1].galleryLength, 4);
      expect(result[2].assetId, 'next');
      expect(result[2].galleryPosition, isNull);
    });

    test('gallery at non-current position emits all images', () {
      final items = [
        _makeAsset(id: 'a'),
        _makeAsset(
          id: 'gal',
          isGallery: true,
          galleryUrls: [
            'https://i.redd.it/gal_0.jpg',
            'https://i.redd.it/gal_1.jpg',
            'https://i.redd.it/gal_2.jpg',
          ],
        ),
        _makeAsset(id: 'c'),
      ];
      final result = planner.plan(
        items: items,
        currentIndex: 0,
        horizon: 3,
        needCount: 10,
        generation: 1,
      );
      // index 0 = image, index 1 = gallery (3 images), index 2 = image, index 3 = beyond end
      expect(result.length, 5);
      expect(result[0].assetId, 'a');
      expect(result[1].assetId, 'gal');
      expect(result[1].galleryPosition, 0);
      expect(result[2].assetId, 'gal');
      expect(result[2].galleryPosition, 1);
      expect(result[3].assetId, 'gal');
      expect(result[3].galleryPosition, 2);
      expect(result[4].assetId, 'c');
    });

    test('galleryIndex at end of gallery (no remaining)', () {
      final items = [
        _makeAsset(
          id: 'gal',
          isGallery: true,
          galleryUrls: [
            'https://i.redd.it/gal_0.jpg',
            'https://i.redd.it/gal_1.jpg',
          ],
        ),
        _makeAsset(id: 'next'),
      ];
      final result = planner.plan(
        items: items,
        currentIndex: 0,
        horizon: 2,
        needCount: 10,
        generation: 1,
        galleryIndex: 1, // last image
      );
      // No remaining gallery images, should move to next post
      expect(result.length, 1);
      expect(result[0].assetId, 'next');
    });

    test('galleryIndex beyond gallery length handled', () {
      final items = [
        _makeAsset(
          id: 'gal',
          isGallery: true,
          galleryUrls: ['https://i.redd.it/gal_0.jpg'],
        ),
        _makeAsset(id: 'next'),
      ];
      final result = planner.plan(
        items: items,
        currentIndex: 0,
        horizon: 2,
        needCount: 10,
        generation: 1,
        galleryIndex: 5, // beyond length, no images remain
      );
      expect(result.length, 1);
      expect(result[0].assetId, 'next');
    });

    test('non-gallery current position ignores galleryIndex', () {
      final items = [
        _makeAsset(id: 'a'),
        _makeAsset(id: 'b'),
      ];
      final result = planner.plan(
        items: items,
        currentIndex: 0,
        horizon: 2,
        needCount: 10,
        generation: 1,
        galleryIndex: 0,
      );
      expect(result.length, 2);
      expect(result[0].assetId, 'a');
      expect(result[1].assetId, 'b');
    });

    test('gallery with empty urls treated as regular image', () {
      final items = [
        _makeAsset(id: 'empty_gal', isGallery: true, galleryUrls: []),
        _makeAsset(id: 'next'),
      ];
      final result = planner.plan(
        items: items,
        currentIndex: 0,
        horizon: 2,
        needCount: 10,
        generation: 1,
      );
      // Empty gallery treated as regular image (mediaUrl)
      expect(result.length, 2);
      expect(result[0].assetId, 'empty_gal');
      expect(result[0].mediaType, MediaTaskType.image);
      expect(result[1].assetId, 'next');
    });

    test('gallery with null urls treated as regular image', () {
      final items = [
        _makeAsset(id: 'null_gal', isGallery: true, galleryUrls: null),
        _makeAsset(id: 'next'),
      ];
      final result = planner.plan(
        items: items,
        currentIndex: 0,
        horizon: 2,
        needCount: 10,
        generation: 1,
      );
      expect(result.length, 2);
      expect(result[0].assetId, 'null_gal');
      expect(result[0].mediaType, MediaTaskType.image);
    });
  });

  group('videos', () {
    test('video with thumbnail and videoUrl generates two tasks', () {
      final items = [
        _makeAsset(
          id: 'vid',
          isVideo: true,
          thumbnailUrl: 'https://i.redd.it/vid_thumb.jpg',
          videoUrl: 'https://v.redd.it/vid.mp4',
        ),
      ];
      final result = planner.plan(
        items: items,
        currentIndex: 0,
        horizon: 1,
        needCount: 10,
        generation: 1,
      );
      expect(result.length, 2);
      expect(result[0].url, 'https://i.redd.it/vid_thumb.jpg');
      expect(result[0].mediaType, MediaTaskType.image);
      expect(result[1].url, 'https://v.redd.it/vid.mp4');
      expect(result[1].mediaType, MediaTaskType.video);
      expect(result[0].assetId, 'vid');
      expect(result[1].assetId, 'vid');
    });

    test('video without videoUrl generates one image task', () {
      final items = [
        MediaAsset(
          id: 'vid_no_url',
          title: 'Test',
          author: 'test',
          score: 0,
          subreddit: 'test',
          mediaUrl: 'https://i.redd.it/vid.jpg',
          videoUrl: null,
          thumbnailUrl: 'https://i.redd.it/vid_thumb.jpg',
          isVideo: true,
          isGallery: false,
          nsfw: false,
          qualityScore: 0,
          galleryUrls: null,
          createdUtc: 0,
        ),
      ];
      final result = planner.plan(
        items: items,
        currentIndex: 0,
        horizon: 1,
        needCount: 10,
        generation: 1,
      );
      expect(result.length, 1);
      expect(result[0].mediaType, MediaTaskType.image);
      expect(result[0].url, 'https://i.redd.it/vid_thumb.jpg');
    });

    test('video without thumbnail falls back to mediaUrl', () {
      final items = [
        MediaAsset(
          id: 'vid_no_thumb',
          title: 'Test',
          author: 'test',
          score: 0,
          subreddit: 'test',
          mediaUrl: 'https://i.redd.it/fallback.jpg',
          videoUrl: 'https://v.redd.it/vid.mp4',
          thumbnailUrl: null,
          isVideo: true,
          isGallery: false,
          nsfw: false,
          qualityScore: 0,
          galleryUrls: null,
          createdUtc: 0,
        ),
      ];
      final result = planner.plan(
        items: items,
        currentIndex: 0,
        horizon: 1,
        needCount: 10,
        generation: 1,
      );
      // No thumbnail → no image task, just video task
      expect(result.length, 1);
      expect(result[0].mediaType, MediaTaskType.video);
      expect(result[0].url, 'https://v.redd.it/vid.mp4');
    });
  });

  group('duplicate prevention', () {
    test('same URL at multiple positions generates only one task', () {
      final items = [
        _makeAsset(id: 'a', mediaUrl: 'https://i.redd.it/same.jpg'),
        _makeAsset(id: 'b', mediaUrl: 'https://i.redd.it/same.jpg'),
      ];
      final result = planner.plan(
        items: items,
        currentIndex: 0,
        horizon: 2,
        needCount: 10,
        generation: 1,
      );
      // Both positions share same URL → only one task
      expect(result.length, 1);
    });

    test('duplicate URL across gallery and regular handled', () {
      final items = [
        _makeAsset(
          id: 'gal',
          isGallery: true,
          galleryUrls: [
            'https://i.redd.it/common.jpg',
            'https://i.redd.it/unique.jpg',
          ],
        ),
        _makeAsset(id: 'dup', mediaUrl: 'https://i.redd.it/common.jpg'),
      ];
      final result = planner.plan(
        items: items,
        currentIndex: 0,
        horizon: 2,
        needCount: 10,
        generation: 1,
      );
      // Remaining gallery: unique.jpg (galleryIndex=0, so index 1 is remaining)
      // Next post: common.jpg, but it's already seen (in position 0's gallery as current)
      // wait, no: galleryUrls[0]=common.jpg is CURRENT (not emitted as remaining),
      // so common.jpg is NOT in seenUrls yet.
      // Result should be: unique.jpg (remaining gallery), then common.jpg (next post)
      expect(result.length, 2);
      expect(result[0].url, 'https://i.redd.it/unique.jpg');
      expect(result[1].url, 'https://i.redd.it/common.jpg');
    });
  });

  group('determinism', () {
    test('same input produces identical output', () {
      final items = List.generate(10, (i) => _makeAsset(id: 'item_$i'));
      final input = {
        'items': items,
        'currentIndex': 2,
        'horizon': 5,
        'needCount': 7,
        'generation': 3,
      };

      final result1 = planner.plan(
        items: input['items'] as List<MediaAsset>,
        currentIndex: input['currentIndex'] as int,
        horizon: input['horizon'] as int,
        needCount: input['needCount'] as int,
        generation: input['generation'] as int,
      );
      final result2 = planner.plan(
        items: input['items'] as List<MediaAsset>,
        currentIndex: input['currentIndex'] as int,
        horizon: input['horizon'] as int,
        needCount: input['needCount'] as int,
        generation: input['generation'] as int,
      );

      expect(result1.length, result2.length);
      for (int i = 0; i < result1.length; i++) {
        expect(result1[i].url, result2[i].url);
        expect(result1[i].index, result2[i].index);
        expect(result1[i].generation, result2[i].generation);
      }
    });

    test('ordering is stable regardless of needCount', () {
      final items = List.generate(10, (i) => _makeAsset(id: 'item_$i'));
      final full = planner.plan(
        items: items,
        currentIndex: 0,
        horizon: 5,
        needCount: 100,
        generation: 1,
      );
      final partial = planner.plan(
        items: items,
        currentIndex: 0,
        horizon: 5,
        needCount: 3,
        generation: 1,
      );
      // Partial should be first 3 of full
      expect(partial.length, 3);
      expect(partial[0].url, full[0].url);
      expect(partial[1].url, full[1].url);
      expect(partial[2].url, full[2].url);
    });
  });

  group('mixed content', () {
    test('image, gallery, video, image produces correct ordering', () {
      final items = [
        _makeAsset(id: 'img0'),
        _makeAsset(
          id: 'gal',
          isGallery: true,
          galleryUrls: [
            'https://i.redd.it/gal_a.jpg',
            'https://i.redd.it/gal_b.jpg',
          ],
        ),
        _makeAsset(id: 'vid', isVideo: true),
        _makeAsset(id: 'img1'),
      ];
      final result = planner.plan(
        items: items,
        currentIndex: 0,
        horizon: 5,
        needCount: 10,
        generation: 1,
      );
      // img0, gal_a, gal_b, vid_thumb, vid_video, img1
      expect(result.length, 6);
      expect(result[0].assetId, 'img0');
      expect(result[1].assetId, 'gal');
      expect(result[1].galleryPosition, 0);
      expect(result[2].assetId, 'gal');
      expect(result[2].galleryPosition, 1);
      expect(result[3].assetId, 'vid');
      expect(result[3].mediaType, MediaTaskType.image);
      expect(result[4].assetId, 'vid');
      expect(result[4].mediaType, MediaTaskType.video);
      expect(result[5].assetId, 'img1');
    });

    test('needCount in middle of gallery emits correct subset', () {
      final items = [
        _makeAsset(
          id: 'gal',
          isGallery: true,
          galleryUrls: [
            'https://i.redd.it/gal_0.jpg',
            'https://i.redd.it/gal_1.jpg',
            'https://i.redd.it/gal_2.jpg',
            'https://i.redd.it/gal_3.jpg',
            'https://i.redd.it/gal_4.jpg',
          ],
        ),
        _makeAsset(id: 'next'),
      ];
      final result = planner.plan(
        items: items,
        currentIndex: 0,
        horizon: 3,
        needCount: 2,
        generation: 1,
      );
      expect(result.length, 2);
      expect(result[0].galleryPosition, 1);
      expect(result[1].galleryPosition, 2);
    });
  });

  group('SchedulerTask', () {
    test('is immutable', () {
      const task = SchedulerTask(
        assetId: 'a',
        url: 'https://i.redd.it/a.jpg',
        index: 0,
        mediaType: MediaTaskType.image,
        generation: 1,
      );
      expect(task.assetId, 'a');
      expect(task.url, 'https://i.redd.it/a.jpg');
    });

    test('gallery fields are null for non-gallery tasks', () {
      const task = SchedulerTask(
        assetId: 'a',
        url: 'https://i.redd.it/a.jpg',
        index: 0,
        mediaType: MediaTaskType.image,
        generation: 1,
      );
      expect(task.galleryPosition, isNull);
      expect(task.galleryLength, isNull);
    });

    test('gallery fields populated for gallery tasks', () {
      const task = SchedulerTask(
        assetId: 'gal',
        url: 'https://i.redd.it/gal_2.jpg',
        index: 0,
        mediaType: MediaTaskType.image,
        galleryPosition: 2,
        galleryLength: 5,
        generation: 1,
      );
      expect(task.galleryPosition, 2);
      expect(task.galleryLength, 5);
    });

    test('video type distinguishes from image', () {
      const imageTask = SchedulerTask(
        assetId: 'a',
        url: 'https://i.redd.it/a.jpg',
        index: 0,
        mediaType: MediaTaskType.image,
        generation: 1,
      );
      const videoTask = SchedulerTask(
        assetId: 'b',
        url: 'https://v.redd.it/b.mp4',
        index: 0,
        mediaType: MediaTaskType.video,
        generation: 1,
      );
      expect(imageTask.mediaType, MediaTaskType.image);
      expect(videoTask.mediaType, MediaTaskType.video);
    });
  });
}
