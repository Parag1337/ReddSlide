import 'dart:developer';

class Trace {
  static int _seq = 0;
  static bool enabled = true;

  /// Emit a structured trace event.
  ///
  /// Format: [VT] seq=1 | source=name | key=val | key=val | ...
  ///
  /// Use [source] to identify the file/class emitting the event.
  /// [kv] is a list of key-value pairs interleaved as [key1, val1, key2, val2, ...].
  static void t(String source, List<Object?> kv) {
    if (!enabled) return;
    _seq++;
    final buf = StringBuffer()
      ..write('[VT] seq=$_seq | source=$source');
    for (int i = 0; i + 1 < kv.length; i += 2) {
      buf.write(' | ${kv[i]}=${kv[i + 1]}');
    }
    log(buf.toString(), name: 'VT');
  }
}
