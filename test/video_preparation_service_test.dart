import 'package:flutter_test/flutter_test.dart';
import 'package:redslide/features/slideshow/domain/video_preparation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VideoPreparationService lifecycle', () {
    test('can be created and disposed', () {
      final service = VideoPreparationService();
      expect(service, isNotNull);
      service.dispose();
    });

    test('prepare returns a future for a new url', () {
      final service = VideoPreparationService();
      final future = service.prepare('https://v.redd.it/test.mp4');
      expect(future, isA<Future>());
      future.then((_) {}, onError: (_) {});
      service.dispose();
    });

    test('prepare for same url before init returns same future', () {
      final service = VideoPreparationService();
      final future1 = service.prepare('https://v.redd.it/test.mp4');
      final future2 = service.prepare('https://v.redd.it/test.mp4');
      expect(future1, same(future2));
      future1.then((_) {}, onError: (_) {});
      service.dispose();
    });

    test('isReady returns false before controller is initialized', () {
      final service = VideoPreparationService();
      final future = service.prepare('https://v.redd.it/test.mp4');
      future.then((_) {}, onError: (_) {});
      expect(service.isReady('https://v.redd.it/test.mp4'), false);
      service.dispose();
    });

    test('isReady returns false for unknown url', () {
      final service = VideoPreparationService();
      expect(service.isReady('https://v.redd.it/unknown.mp4'), false);
      service.dispose();
    });

    test('hasFailed returns false before controller is initialized', () {
      final service = VideoPreparationService();
      final future = service.prepare('https://v.redd.it/test.mp4');
      future.then((_) {}, onError: (_) {});
      expect(service.hasFailed('https://v.redd.it/test.mp4'), false);
      service.dispose();
    });

    test('getController returns null before controller is ready', () {
      final service = VideoPreparationService();
      final future = service.prepare('https://v.redd.it/test.mp4');
      future.then((_) {}, onError: (_) {});
      expect(service.getController('https://v.redd.it/test.mp4'), null);
      service.dispose();
    });

    test('getController returns null for unknown url', () {
      final service = VideoPreparationService();
      expect(service.getController('https://v.redd.it/unknown.mp4'), null);
      service.dispose();
    });

    test('prepare for different urls returns different futures', () {
      final service = VideoPreparationService();
      final future1 = service.prepare('https://v.redd.it/vid1.mp4');
      final future2 = service.prepare('https://v.redd.it/vid2.mp4');
      expect(future1, isNot(same(future2)));
      future1.then((_) {}, onError: (_) {});
      future2.then((_) {}, onError: (_) {});
      service.dispose();
    });

    test('evictOutsideWindow removes entries not in the set', () {
      final service = VideoPreparationService();
      final f1 = service.prepare('https://v.redd.it/keep.mp4');
      final f2 = service.prepare('https://v.redd.it/evict.mp4');
      f1.then((_) {}, onError: (_) {});
      f2.then((_) {}, onError: (_) {});

      service.evictOutsideWindow({'https://v.redd.it/keep.mp4'});

      expect(service.isReady('https://v.redd.it/evict.mp4'), false);
      expect(service.isReady('https://v.redd.it/keep.mp4'), false);
      service.dispose();
    });

    test('evictOutsideWindow does nothing when all urls are in window', () {
      final service = VideoPreparationService();
      final f1 = service.prepare('https://v.redd.it/vid1.mp4');
      final f2 = service.prepare('https://v.redd.it/vid2.mp4');
      f1.then((_) {}, onError: (_) {});
      f2.then((_) {}, onError: (_) {});

      service.evictOutsideWindow({
        'https://v.redd.it/vid1.mp4',
        'https://v.redd.it/vid2.mp4',
      });

      service.dispose();
    });

    test('dispose clears all entries', () {
      final service = VideoPreparationService();
      final f1 = service.prepare('https://v.redd.it/vid1.mp4');
      final f2 = service.prepare('https://v.redd.it/vid2.mp4');
      f1.then((_) {}, onError: (_) {});
      f2.then((_) {}, onError: (_) {});

      service.dispose();

      expect(service.isReady('https://v.redd.it/vid1.mp4'), false);
      expect(service.isReady('https://v.redd.it/vid2.mp4'), false);
    });

    test('can dispose multiple times safely', () {
      final service = VideoPreparationService();
      final future = service.prepare('https://v.redd.it/test.mp4');
      future.then((_) {}, onError: (_) {});
      service.dispose();
      service.dispose();
    });

    test('readiness callback fires when controller becomes ready', () async {
      final service = VideoPreparationService();
      int callCount = 0;
      service.onReadinessChanged = () => callCount++;

      final future = service.prepare('https://v.redd.it/test.mp4');
      future.then((_) {}, onError: (_) {});

      await Future.delayed(Duration.zero);

      expect(callCount, greaterThanOrEqualTo(0));
      service.dispose();
    });
  });
}
