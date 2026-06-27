import 'dart:developer';

int _nextPipelineId = 0;
int _nextPipelineIdGen() => ++_nextPipelineId;

class PipelineTimer {
  final int id;
  final String label;
  final Stopwatch _sw = Stopwatch();
  int _lastMark = 0;

  PipelineTimer({required this.label}) : id = _nextPipelineIdGen() {
    _sw.start();
    _lastMark = 0;
    log('[RENDER_TIMELINE] pid=$id label=$label START');
  }

  void mark(String stage) {
    final elapsed = _sw.elapsedMilliseconds;
    final sinceLast = elapsed - _lastMark;
    _lastMark = elapsed;
    log('[RENDER_TIMELINE] pid=$id label=$label stage=$stage '
        'elapsed=${elapsed}ms sinceLast=${sinceLast}ms');
  }

  void end() {
    _sw.stop();
    final elapsed = _sw.elapsedMilliseconds;
    final sinceLast = elapsed - _lastMark;
    log('[RENDER_TIMELINE] pid=$id label=$label stage=END '
        'elapsed=${elapsed}ms sinceLast=${sinceLast}ms');
  }
}
