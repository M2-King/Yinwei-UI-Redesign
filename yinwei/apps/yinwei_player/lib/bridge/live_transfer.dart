import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:yinwei_player/bridge/live_capture_health.dart';
import 'package:yinwei_player/bridge/yinwei_bindings.dart';
import 'package:yinwei_player/models/spatial_params.dart';
import 'package:yinwei_player/platform/platform_capabilities.dart';

/// Controls WASAPI loopback → HRTF live transfer in `spatial_core`.
class LiveTransferController extends ChangeNotifier {
  LiveTransferController({PlatformCapabilities? capabilities})
      : _capabilities = capabilities ?? PlatformCapabilities.detect();

  final PlatformCapabilities _capabilities;

  bool running = false;
  bool starting = false;
  String? lastError;
  int lastPid = 0;
  int capturedFrames = 0;
  int energyFrames = 0;
  int? lastEnergyAgeMs;
  bool captureHealthy = false;
  List<String> outputDevices = const [];
  String selectedOutput = '';
  String defaultOutputName = '';

  int _prevCaptured = 0;
  int _prevEnergy = 0;
  int _nativeDownTicks = 0;
  int _reconnectFails = 0;
  bool _reconnecting = false;
  SpatialParams? _appliedParams;
  ArrayLayout? _appliedArray;
  int _sessionGen = 0;

  YinweiBindings? get _b => YinweiBindings.tryLoad();

  /// Product gate. Independent of whether `yinwei_live_*` stubs exist.
  bool get capabilityEnabled => _capabilities.liveTransfer;

  bool get available {
    if (!_capabilities.liveTransfer) return false;
    final b = _b;
    if (b == null) return false;
    try {
      b.liveIsRunning();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Full-window idle label is `真实Transfer`; island uses `全窗Transfer`.
  String toggleLabel({required String idle}) {
    if (running) return 'HRTF ON';
    if (starting) return '连接中';
    return idle;
  }

  void refreshDevices() {
    final b = _b;
    if (b == null) return;
    try {
      outputDevices = b.liveListOutputDevices();
    } catch (_) {
      // Optional symbol — older DLLs have no device list.
    }
    try {
      defaultOutputName = b.liveDefaultOutputDevice();
    } catch (_) {
      defaultOutputName = '';
    }
    notifyListeners();
  }

  void setOutputDevice(String name) {
    selectedOutput = name;
    final b = _b;
    if (b != null) {
      try {
        b.liveSetOutputDevice(name);
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Show 连接中 before the PowerShell pin (start() also sets this).
  void markStarting() {
    lastError = null;
    starting = true;
    running = false;
    notifyListeners();
  }

  /// Hold wet silent until the source is pinned to muted speakers.
  /// Returns false when the native symbol is missing (pin first, then start).
  bool setOutputHold(bool hold) {
    final b = _b;
    if (b == null) return false;
    try {
      return b.liveSetOutputHold(hold) == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> start({
    required int processId,
    SpatialParams? params,
    ArrayLayout? array,
  }) async {
    if (!_capabilities.liveTransfer) {
      fail('Live Transfer is Windows-only');
      return;
    }
    final b = _b;
    if (b == null) {
      fail('spatial_core.dll not loaded — run build_native_windows.ps1');
      return;
    }
    lastError = null;
    lastPid = processId;
    _appliedParams = params;
    if (array != null) _appliedArray = array.copy();
    _nativeDownTicks = 0;
    _reconnectFails = 0;
    _sessionGen++;
    final gen = _sessionGen;
    capturedFrames = 0;
    energyFrames = 0;
    lastEnergyAgeMs = null;
    captureHealthy = false;
    _prevCaptured = 0;
    _prevEnergy = 0;
    starting = true;
    running = false;
    notifyListeners();

    try {
      b.liveSetOutputDevice(selectedOutput);
    } catch (_) {
      // Older DLL without device picker — default output only.
    }

    // Never mute the source app session. Blocking WASAPI start runs off the
    // UI isolate so the Transfer button can show 连接中 immediately.
    final int code;
    final String err;
    try {
      final started = await _ffiLiveStart(processId);
      code = started.$1;
      err = started.$2;
    } catch (e) {
      if (gen != _sessionGen) return;
      starting = false;
      fail(e.toString());
      return;
    }
    if (gen != _sessionGen) {
      // Newer start/retarget owns the native engine — do not liveStop.
      return;
    }
    if (code != 0) {
      starting = false;
      fail(err.isEmpty ? 'yinwei_live_start failed ($code)' : err);
      return;
    }

    if (params != null) {
      final pc = b.liveSetParams(
        azimuthDeg: params.azimuthDeg,
        elevationDeg: params.elevationDeg,
        distanceM: params.distanceM,
        motion: params.motion == MotionMode.orbit ? 1 : 0,
        orbitHz: params.orbitHz,
        envelopment: params.envelopment,
        reverbMix: params.reverbMix,
        preset: _presetIndex(params.selectedPreset),
      );
      if (pc != 0) {
        b.liveStop();
        fail(b.readLastError().isEmpty
            ? 'yinwei_live_set_params failed ($pc)'
            : b.readLastError());
        return;
      }
      try {
        b.liveSetEq(params.eqDb);
      } catch (_) {}
    }
    final mc = b.liveSetMode(1); // Spatial
    if (mc != 0) {
      b.liveStop();
      fail(b.readLastError().isEmpty
          ? 'yinwei_live_set_mode failed ($mc)'
          : b.readLastError());
      return;
    }

    capturedFrames = b.liveCapturedFrames();
    energyFrames = _readEnergyFrames(b);
    starting = false;
    running = true;
    lastError = null;
    if (_appliedArray != null) applyLiveArray(_appliedArray!);
    _refreshHealth(b);
    notifyListeners();
  }

  /// Rebind process loopback to [processId] without dropping Transfer.
  ///
  /// Keeps wet output device and Spatial/EQ. UI stays HRTF ON so speaker
  /// routing is not restored mid-hop.
  Future<void> retarget({required int processId, SpatialParams? params}) async {
    if (processId <= 0) return;
    if (processId == lastPid && running && !_reconnecting) return;
    final b = _b;
    if (b == null) return;
    lastPid = processId;
    if (params != null) _appliedParams = params;
    _nativeDownTicks = 0;
    _reconnectFails = 0;
    _sessionGen++;
    final gen = _sessionGen;
    _reconnecting = true;
    try {
      try {
        b.liveSetOutputDevice(selectedOutput);
      } catch (_) {}
      final (code, err) = await _ffiLiveStart(processId);
      if (gen != _sessionGen) return;
      if (code != 0) {
        lastError = err.isEmpty ? 'live retarget failed ($code)' : err;
        notifyListeners();
        return;
      }
      running = true;
      starting = false;
      lastError = null;
      _nativeDownTicks = 0;
      _reconnectFails = 0;
      final applied = _appliedParams;
      if (applied != null) {
        applyLiveParams(applied);
      }
      if (_appliedArray != null) {
        applyLiveArray(_appliedArray!);
      }
      try {
        b.liveSetMode(1);
      } catch (_) {}
      capturedFrames = b.liveCapturedFrames();
      energyFrames = _readEnergyFrames(b);
      _refreshHealth(b);
      notifyListeners();
    } catch (e) {
      if (gen != _sessionGen) return;
      lastError = e.toString();
      notifyListeners();
    } finally {
      if (gen == _sessionGen) {
        _reconnecting = false;
      }
    }
  }

  /// Pose / Spatial params while live is running. Returns false on FFI error.
  bool applyLiveParams(SpatialParams params) {
    final b = _b;
    if (b == null || !running) return false;
    try {
      final pc = b.liveSetParams(
        azimuthDeg: params.azimuthDeg,
        elevationDeg: params.elevationDeg,
        distanceM: params.distanceM,
        motion: params.motion == MotionMode.orbit ? 1 : 0,
        orbitHz: params.orbitHz,
        envelopment: params.envelopment,
        reverbMix: params.reverbMix,
        preset: _presetIndex(params.selectedPreset),
      );
      if (pc != 0) {
        lastError = b.readLastError().isEmpty
            ? 'yinwei_live_set_params failed ($pc)'
            : b.readLastError();
        notifyListeners();
        return false;
      }
      try {
        b.liveSetEq(params.eqDb);
      } catch (_) {}
      return true;
    } catch (e) {
      lastError = e.toString();
      notifyListeners();
      return false;
    }
  }

  bool applyLiveArray(ArrayLayout layout) {
    final b = _b;
    if (b == null || !running) return false;
    _appliedArray = layout.copy();
    try {
      final mc = b.liveSetArray(layout.nativeMode);
      if (mc == -1) return false;
      if (mc != 0) {
        lastError = b.readLastError().isEmpty
            ? 'yinwei_live_set_array failed ($mc)'
            : b.readLastError();
        notifyListeners();
        return false;
      }
      if (!layout.enabled) return true;
      final cc = b.liveSetSpeakerCount(layout.speakers.length);
      if (cc == -1 && layout.speakers.length > 2) {
        lastError = '当前 DLL 不含加点，只有 L/R 会发声。请完全退出后换新 spatial_core.dll';
        notifyListeners();
        return false;
      }
      if (cc != 0 && cc != -1) {
        lastError = b.readLastError().isEmpty
            ? 'yinwei_live_set_speaker_count failed ($cc)'
            : b.readLastError();
        notifyListeners();
        return false;
      }
      for (var i = 0; i < layout.speakers.length; i++) {
        final s = layout.speakers[i];
        final sc = b.liveSetSpeaker(
          index: i,
          azimuthDeg: s.azimuthDeg,
          elevationDeg: s.elevationDeg,
          distanceM: s.distanceM,
          gainDb: s.gainDb,
          mute: s.mute,
          feed: s.nativeFeed,
        );
        if (sc != 0 && sc != -1) {
          lastError = b.readLastError().isEmpty
              ? 'yinwei_live_set_speaker failed ($sc)'
              : b.readLastError();
          notifyListeners();
          return false;
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  bool applyLiveMode(PlaybackMode mode) {
    final b = _b;
    if (b == null || !running) return false;
    try {
      final mc = b.liveSetMode(mode == PlaybackMode.spatial ? 1 : 0);
      if (mc != 0) {
        lastError = b.readLastError().isEmpty
            ? 'yinwei_live_set_mode failed ($mc)'
            : b.readLastError();
        notifyListeners();
        return false;
      }
      return true;
    } catch (e) {
      lastError = e.toString();
      notifyListeners();
      return false;
    }
  }

  void fail(String message) {
    lastError = message;
    running = false;
    starting = false;
    captureHealthy = false;
    notifyListeners();
  }

  Future<void> stop() async {
    _sessionGen++;
    _reconnecting = false;
    starting = false;
    final b = _b;
    b?.liveStop();
    running = false;
    capturedFrames = 0;
    energyFrames = 0;
    lastEnergyAgeMs = null;
    captureHealthy = false;
    _prevCaptured = 0;
    _prevEnergy = 0;
    notifyListeners();
  }

  void refreshTelemetry({bool notify = true}) {
    final b = _b;
    if (b == null || !running || _reconnecting) return;
    capturedFrames = b.liveCapturedFrames();
    energyFrames = _readEnergyFrames(b);
    if (!b.liveIsRunning()) {
      // SMTC flakes / WASAPI hops used to mark Transfer dead. Stay on and
      // reopen the native engine; do not restore speaker routing here.
      _nativeDownTicks++;
      if (_nativeDownTicks >= 2 && lastPid > 0) {
        _reconnecting = true;
        unawaited(_reconnectNative());
      }
      return;
    }
    _nativeDownTicks = 0;
    _reconnectFails = 0;
    lastError = null;
    _refreshHealth(b);
    if (notify) notifyListeners();
  }

  Future<void> _reconnectNative() async {
    final b = _b;
    final pid = lastPid;
    final params = _appliedParams;
    final gen = _sessionGen;
    try {
      if (b == null || pid <= 0) return;
      try {
        b.liveSetOutputDevice(selectedOutput);
      } catch (_) {}
      final (code, err) = await _ffiLiveStart(pid);
      if (gen != _sessionGen) {
        return;
      }
      if (code != 0) {
        _reconnectFails++;
        if (_reconnectFails >= 8) {
          fail(err.isEmpty ? 'Live capture stopped' : err);
        }
        return;
      }
      running = true;
      lastError = null;
      _nativeDownTicks = 0;
      _reconnectFails = 0;
      if (params != null) {
        applyLiveParams(params);
      }
      if (_appliedArray != null) {
        applyLiveArray(_appliedArray!);
      }
      b.liveSetMode(1);
      _refreshHealth(b);
      notifyListeners();
    } catch (e) {
      if (gen != _sessionGen) return;
      _reconnectFails++;
      if (_reconnectFails >= 8) {
        fail(e.toString());
      }
    } finally {
      if (gen == _sessionGen) {
        _reconnecting = false;
      }
    }
  }

  Future<(int, String)> _ffiLiveStart(int processId) async {
    final libPath = YinweiBindings.resolvedLibraryPath;
    if (libPath == null || libPath.isEmpty) {
      final b = _b;
      if (b == null) {
        return (
          -1,
          'spatial_core.dll not loaded — run build_native_windows.ps1',
        );
      }
      final code = b.liveStart(processId);
      return (code, code != 0 ? b.readLastError() : '');
    }
    return Isolate.run(() {
      final b = YinweiBindings.loadFromPath(libPath);
      final code = b.liveStart(processId);
      return (code, code != 0 ? b.readLastError() : '');
    });
  }

  void _refreshHealth(YinweiBindings b) {
    lastEnergyAgeMs = _readEnergyAgeMs(b);
    captureHealthy = LiveCaptureHealth(
      running: running,
      capturedFrames: capturedFrames,
      energyFrames: energyFrames,
      prevCapturedFrames: _prevCaptured,
      prevEnergyFrames: _prevEnergy,
      lastEnergyAgeMs: lastEnergyAgeMs,
    ).healthy;
    _prevCaptured = capturedFrames;
    _prevEnergy = energyFrames;
  }

  int _readEnergyFrames(YinweiBindings b) {
    try {
      return b.liveEnergyFrames();
    } catch (_) {
      return 0;
    }
  }

  int? _readEnergyAgeMs(YinweiBindings b) {
    try {
      final stamp = b.liveLastEnergyMs();
      if (stamp <= 0) return null;
      final now = DateTime.now().millisecondsSinceEpoch;
      return (now - stamp).clamp(0, 1 << 30);
    } catch (_) {
      return null;
    }
  }

  double azimuthDeg() => _b?.liveAzimuthDeg() ?? 0;
  double elevationDeg() => _b?.liveElevationDeg() ?? 0;

  static int _presetIndex(PositionPreset? p) {
    if (p == null) return -1;
    return PositionPreset.values.indexOf(p);
  }
}
