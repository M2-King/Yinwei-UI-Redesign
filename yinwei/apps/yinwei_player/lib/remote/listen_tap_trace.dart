import 'dart:convert';

import 'dart:developer' as developer;

/// Bounded control-path diagnostics. Never records credentials, titles, provider
/// identities, addresses or audio. Wall clocks on different devices need not
/// agree: compare durations within one device, and match command IDs across it.
class ListenTapTrace {
  static final _clock = Stopwatch()..start();
  static final _rows = <Map<String, Object?>>[];
  static int _untilUs = 0;

  static void begin(String phase, [Map<String, Object?> fields = const {}]) {
    _untilUs = _clock.elapsedMicroseconds + 30000000;
    mark(phase, fields);
  }

  static void mark(String phase, [Map<String, Object?> fields = const {}]) {
    if (_clock.elapsedMicroseconds > _untilUs) return;
    final row = <String, Object?>{
      'phase': phase,
      'epochMs': DateTime.now().millisecondsSinceEpoch,
      'elapsedUs': _clock.elapsedMicroseconds,
      ...fields,
    };
    if (_rows.length == 256) _rows.removeAt(0);
    _rows.add(row);
    developer.log(jsonEncode(row), name: 'ListenTap');
  }

  static List<Map<String, Object?>> snapshot() =>
      _rows.map((r) => Map<String, Object?>.of(r)).toList();
}
