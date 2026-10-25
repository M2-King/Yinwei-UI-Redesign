import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract class GestureSettingsStore {
  Future<Map<String, bool>> load();
  Future<void> save(Map<String, bool> value);
}

/// Same application-support storage as listen_sound_quality; never a laptop setting.
class FileGestureSettingsStore implements GestureSettingsStore {
  FileGestureSettingsStore({required this.directoryProvider});
  final Future<Directory> Function() directoryProvider;

  Future<File> _file() async => File(
      '${(await directoryProvider()).path}${Platform.pathSeparator}listen_gestures.json');

  @override
  Future<Map<String, bool>> load() async {
    try {
      final value = jsonDecode(await (await _file()).readAsString());
      if (value is Map) {
        return {'on': value['on'] == true, 'consent': value['consent'] == true};
      }
    } catch (_) {
      // Missing, corrupt or inaccessible settings always default to camera off.
    }
    return {'on': false, 'consent': false};
  }

  @override
  Future<void> save(Map<String, bool> value) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(value), flush: true);
  }
}

/// Owns camera permission, local preference and the camera lifetime, never playback.
/// Remembered "on" is a preference, not permission to reopen the camera after a pause.
class ListenGestures extends ChangeNotifier {
  ListenGestures({
    required this.store,
    MethodChannel? methods,
    Stream<Object?>? events,
  })  : _methods = methods ?? const MethodChannel(channelName),
        _events = events ??
            const EventChannel('$channelName/frames').receiveBroadcastStream();

  static const channelName = 'dev.yinwei/hand_gestures';
  final GestureSettingsStore store;
  final MethodChannel _methods;
  final Stream<Object?> _events;
  StreamSubscription<Object?>? _subscription;
  void Function(Map<String, Object?> result)? onResult;
  VoidCallback? onReset;
  bool enabled = false, consent = false, active = false, starting = false;
  bool _ready = false,
      _foreground = true,
      _disposed = false,
      _initialized = false;
  bool _available = true;
  String permission = 'notDetermined';
  String? error;
  int _generation = 0;
  double _lastEventTime = -1, _lastStatusTime = -1;
  Future<void> _writes = Future<void>.value();

  Map<String, Object?> get state => {
        'on': enabled,
        'consent': consent,
        'active': active,
        'starting': starting,
        'permission': permission,
        'error': error,
      };

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    final token = _generation;
    final saved = await store.load();
    if (_disposed || token != _generation) return;
    enabled = saved['on'] == true;
    consent = saved['consent'] == true;
    try {
      _setPermission(await _methods.invokeMethod<Object?>('permission'));
    } catch (_) {
      error = 'Hand gestures are available on the iPad only.';
    }
    _notify(); // No start: every room opening requires an explicit hand-button tap.
  }

  void setContext(
      {required bool ready,
      required bool foreground,
      required bool available}) {
    _ready = ready;
    _foreground = foreground;
    _available = available;
    if ((!ready || !foreground || !available) && (active || starting)) {
      suspend();
    }
  }

  Future<void> acceptConsent() async {
    if (_disposed) return;
    ++_generation;
    consent = true;
    await _persist();
    _notify();
  }

  Future<void> setEnabled(bool value) async {
    if (_disposed) return;
    if (!value) {
      enabled = false;
      error = null;
      suspend(); // Stop before disk I/O, including when permission is still pending.
      await _persist();
      return;
    }
    if (!consent ||
        !_ready ||
        !_foreground ||
        !_available ||
        active ||
        starting) {
      return;
    }
    enabled = true;
    starting = true;
    error = null;
    final token = ++_generation;
    _lastEventTime = _lastStatusTime = -1;
    _subscription ??= _events.listen(_event, onError: (Object _) {
      error = 'The camera is unavailable. Tap the hand button to try again.';
      suspend();
    });
    _notify();
    await _persist();
    if (!_current(token)) return;
    try {
      final result = await _methods.invokeMapMethod<String, Object?>('start');
      if (!_current(token)) {
        return; // A later native start/stop owns the camera now.
      }
      _setPermission(result?['permission']);
      active = result?['active'] == true;
      if (!active) {
        error = permission == 'denied'
            ? 'Camera access is off. Allow it in iPad Settings to use hand gestures.'
            : 'The camera is unavailable. Tap the hand button to try again.';
      }
    } catch (_) {
      if (!_current(token)) return;
      active = false;
      error = 'The camera is unavailable. Tap the hand button to try again.';
    } finally {
      if (_current(token)) {
        starting = false;
        _notify();
      }
    }
  }

  bool _current(int token) =>
      !_disposed && token == _generation && _ready && _foreground && _available;

  void suspend() {
    if (_disposed) return;
    final wasRunning = active || starting;
    ++_generation;
    active = false;
    starting = false;
    _lastEventTime = _lastStatusTime = -1;
    if (wasRunning) unawaited(_stopNative());
    onReset?.call();
    _notify();
  }

  Future<void> _stopNative() async {
    try {
      await _methods.invokeMethod<void>('stop');
    } catch (_) {
      // Unsupported hosts never own a camera.
    }
  }

  Future<void> _persist() {
    final value = {'on': enabled, 'consent': consent};
    _writes = _writes.then((_) async {
      try {
        await store.save(value);
      } catch (_) {
        if (!_disposed) error = 'Could not save the hand-gesture setting.';
      }
    });
    return _writes;
  }

  void _setPermission(Object? value) {
    if (const ['notDetermined', 'denied', 'granted'].contains(value)) {
      permission = value as String;
    }
  }

  void _event(Object? raw) {
    if (_disposed || raw is! Map) return;
    if (raw['state'] == 'stopped') {
      _setPermission(raw['permission']);
      suspend();
      return;
    }
    if (raw['state'] == 'reset') {
      onReset?.call();
      _lastEventTime = _lastStatusTime = -1;
      return;
    }
    if (!enabled || !active || !_ready || !_foreground || !_available) return;
    final value = sanitize(raw);
    if (value == null) return;
    final t = (value['t'] as num).toDouble();
    if (value.containsKey('event')) {
      if (t <= _lastEventTime) return;
      _lastEventTime = t;
    } else {
      if (t <= _lastStatusTime) return;
      _lastStatusTime = t;
    }
    onResult?.call(value);
  }

  static const poses = ['Open_Palm', 'Closed_Fist', 'Victory', 'Thumb_Up'];
  static const swipes = ['swipeLeft', 'swipeRight', 'swipeUp', 'swipeDown'];
  static const eventNames = [...poses, ...swipes];

  static double? _number(Object? value, double low, double high) =>
      value is num && value.isFinite ? value.toDouble().clamp(low, high) : null;

  /// Results only. Camera frames, positions, joints and arbitrary diagnostics are rejected.
  static Map<String, Object?>? sanitize(Object? raw) {
    if (raw is! Map) return null;
    final t = _number(raw['t'], 0, 1e12);
    if (t == null) return null;
    if (raw.containsKey('event')) {
      final latency = _number(raw['latencyMs'], 0, 10000);
      if (!eventNames.contains(raw['event']) || latency == null) return null;
      return {'event': raw['event'], 't': t, 'latencyMs': latency};
    }
    final progress = _number(raw['progress'], 0, 1), pose = raw['pose'];
    if (progress == null || (pose != null && !poses.contains(pose))) {
      return null;
    }
    final strokes = <Map<String, Object?>>[];
    if (raw['strokes'] is List) {
      for (final item in (raw['strokes'] as List).take(16)) {
        if (item is! Map || !swipes.contains(item['event'])) continue;
        final start = _number(item['t'], 0, 1e12);
        final travel = _number(item['travel'], 0, 10);
        final peak = _number(item['peak'], 0, 100);
        final ratio = _number(item['ratio'], 0, 99);
        final gap = item['gap'] == null ? null : _number(item['gap'], 0, 10000);
        if (start == null ||
            travel == null ||
            peak == null ||
            ratio == null ||
            (item['gap'] != null && gap == null) ||
            item['fired'] is! bool) {
          continue;
        }
        strokes.add({
          'event': item['event'],
          't': start,
          'travel': travel,
          'peak': peak,
          'ratio': ratio,
          'gap': gap,
          'fired': item['fired']
        });
      }
    }
    return {'t': t, 'pose': pose, 'progress': progress, 'strokes': strokes};
  }

  static Map<String, Object?> tuning(Object? raw) {
    const defaults = {
      'commitHands': 0.34,
      'commitHandsV': 0.34,
      'swipeSpeed': 2.4,
      'swipeRatio': 1.2,
      'rearmMs': 250.0,
      'returnMs': 600.0
    };
    const floors = {
      'commitHands': 0.25,
      'commitHandsV': 0.25,
      'swipeSpeed': 2.2,
      'swipeRatio': 1.05,
      'rearmMs': 100.0,
      'returnMs': 0.0
    };
    final out = <String, Object?>{'version': 2, ...defaults};
    if (raw is! Map || raw['version'] != 2) return out;
    for (final key in defaults.keys) {
      out[key] =
          _number(raw[key], floors[key]!, defaults[key]!) ?? defaults[key];
    }
    return out;
  }

  Future<double?> configure(Object? value) async {
    if (!_current(_generation) || !active) return null;
    final token = _generation;
    try {
      final t = await _methods.invokeMethod<num>('configure', tuning(value));
      return _current(token) ? _number(t, 0, 1e12) : null;
    } catch (_) {
      if (_current(token)) suspend();
      return null;
    }
  }

  Future<double?> clock() async {
    if (!_current(_generation) || !active) return null;
    final token = _generation;
    try {
      final t = await _methods.invokeMethod<num>('clock');
      return _current(token) ? _number(t, 0, 1e12) : null;
    } catch (_) {
      if (_current(token)) suspend();
      return null;
    }
  }

  /// Only bounded numeric aggregates from the page, never its raw event history.
  static Map<String, Object?> metrics(Object? raw) {
    if (raw is! Map) return {};
    final out = <String, Object?>{};
    for (final name in eventNames) {
      final row = raw[name];
      if (row is! Map) continue;
      final values = <String, Object?>{};
      for (final key in [
        'count',
        'deliveryCount',
        'decisionP50',
        'decisionP95',
        'deliveryP50',
        'deliveryP95',
        'clockUncertaintyMs'
      ]) {
        final v = _number(row[key], 0,
            key.endsWith('count') || key.endsWith('Count') ? 1e9 : 60000);
        if (v != null) values[key] = v;
      }
      out[name] = values;
    }
    return out;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_generation;
    active = false;
    starting = false;
    onResult = null;
    onReset = null;
    unawaited(_subscription?.cancel());
    unawaited(_stopNative());
    super.dispose();
  }
}
