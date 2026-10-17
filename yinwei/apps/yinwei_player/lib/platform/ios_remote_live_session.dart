import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:yinwei_player/platform/replaykit_audio_probe.dart';
import 'package:yinwei_player/remote/remote_transform_client.dart';

/// Bounded stream parser: a fragmented/coalesced Unix read never retains more
/// than one 1,936-byte PCM chunk. No media file or account storage is involved.
class IosCapturePCMParser {
  IosCapturePCMParser(this.onChunk);
  final void Function(Int16List, bool) onChunk;
  final _packet = Uint8List(1936);
  int _filled = 0;
  void add(Uint8List bytes) {
    var offset = 0;
    while (offset < bytes.length) {
      final count = (bytes.length - offset).clamp(0, _packet.length - _filled);
      _packet.setRange(_filled, _filled + count, bytes, offset);
      _filled += count;
      offset += count;
      if (_filled != _packet.length) continue;
      final data = ByteData.sublistView(_packet);
      if (data.getUint32(0, Endian.little) != 0x31434e59 ||
          data.getUint32(4, Endian.little) != 48000 ||
          data.getUint32(8, Endian.little) != 480 ||
          data.getUint32(12, Endian.little) > 1) {
        throw const FormatException('Invalid capture IPC frame');
      }
      final pcm = Int16List(960);
      for (var i = 0; i < 960; ++i) {
        pcm[i] = data.getInt16(16 + i * 2, Endian.little);
      }
      _filled = 0;
      onChunk(pcm, data.getUint32(12, Endian.little) == 1);
    }
  }
}

class IosRemoteLiveSession extends ChangeNotifier {
  IosRemoteLiveSession(
      {MethodChannel? channel,
      ReplayKitAudioProbe? probe,
      Future<ServerSocket> Function(String)? bindIPC})
      : _native =
            channel ?? const MethodChannel(ReplayKitAudioProbe.channelName),
        _probe = probe ?? ReplayKitAudioProbe.create(),
        _bindIPC = bindIPC ?? _bindUnix;
  static Future<ServerSocket> _bindUnix(String path) => ServerSocket.bind(
      InternetAddress(path, type: InternetAddressType.unix), 0,
      shared: false, backlog: 1);
  final Future<ServerSocket> Function(String) _bindIPC;
  final MethodChannel _native;
  final ReplayKitAudioProbe _probe;
  RemoteTransformClient? _client;
  ServerSocket? _server;
  Socket? _capture;
  String? _path;
  Timer? _statusTimer;
  bool busy = false, active = false, signedIn = false, _disposed = false;
  bool _connecting = false;
  bool _operationInFlight = false;
  bool _pollingOutput = false;
  Future<void>? _stopping;
  String status = 'Laptop processing · iPad capture and listening';
  int inputChunks = 0,
      receivedChunks = 0,
      playedChunks = 0,
      outputChunks = 0,
      outputDrops = 0,
      _writes = 0,
      _generation = 0;
  DateTime? _lastCapture;

  Future<Uri> _resolveEntry(String address) async {
    final initial = Uri.tryParse(address.trim());
    if (initial == null ||
        initial.scheme != 'https' ||
        initial.host.isEmpty ||
        initial.userInfo.isNotEmpty ||
        initial.hasQuery ||
        initial.hasFragment ||
        !['', '/'].contains(initial.path)) {
      throw const FormatException('Use your fixed Yinwei HTTPS bookmark');
    }
    // Resolve only a known Cloudflare launcher/temporary origin. Passwords
    // are never sent to the launcher, an arbitrary redirect or an HTTP URL.
    bool quick(Uri uri) =>
        uri.scheme == 'https' &&
        uri.authority == uri.host &&
        RegExp(r'^[a-z0-9-]+\.trycloudflare\.com$').hasMatch(uri.host);
    if (quick(initial)) return initial.replace(path: '');
    if (initial.host !=
        'yinwei-remote-entry-01a12de8.yinwei-01a12de8.workers.dev') {
      throw const FormatException('Use the Yinwei entry link');
    }
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await http.getUrl(initial);
      request.followRedirects = false;
      final response =
          await request.close().timeout(const Duration(seconds: 10));
      final location = response.headers.value('location');
      await response.drain<void>();
      final next = location == null ? null : Uri.tryParse(location);
      if (![301, 302, 303, 307, 308].contains(response.statusCode) ||
          next == null ||
          !quick(next) ||
          next.userInfo.isNotEmpty ||
          next.hasQuery ||
          next.hasFragment ||
          !['', '/', '/remote/signin'].contains(next.path)) {
        throw const FormatException(
            'Laptop connection unavailable. Keep Yinwei running and try again.');
      }
      return next.replace(path: '');
    } finally {
      http.close(force: true);
    }
  }

  Future<void> signIn(String entry, String username, String password) async {
    if (busy || active) return;
    _operationInFlight = true;
    busy = true;
    _changed('Connecting to laptop…');
    final generation = ++_generation;
    try {
      _client?.dispose();
      signedIn = false;
      final origin = await _resolveEntry(entry);
      if (_disposed || generation != _generation) return;
      final client = RemoteTransformClient(
          origin: origin,
          onOutput: acceptReturnAudio,
          onOutputReset: () {
            unawaited(_native
                .invokeMethod<void>('resetRemoteReturn')
                .catchError((Object _) {}));
          },
          onState: (state) {
            if (state == 'disconnected' ||
                state == 'invalidStream' ||
                state == 'slowConnection') {
              unawaited(stop(
                  message: switch (state) {
                'invalidStream' =>
                  'Invalid processed audio received · restart laptop processing',
                'slowConnection' =>
                  'Laptop connection too slow · restart live listening',
                _ => 'Laptop disconnected · tap Start to reconnect',
              }));
            }
          });
      _client = client;
      await client.signIn(username, password);
      if (_disposed || generation != _generation) {
        client.dispose();
        return;
      }
      signedIn = true;
      _changed('Signed in · start only after checking headphone routing');
    } on PlatformException catch (error) {
      _changed(error.message ?? 'Native audio unavailable');
    } catch (_) {
      _changed(
          'Could not sign in. Check the laptop connection and owner login.');
    } finally {
      _operationInFlight = false;
      busy = _stopping != null;
      _changed();
    }
  }

  Future<void> start({required bool routingVerified}) async {
    if (busy || active || !signedIn || !routingVerified) return;
    _operationInFlight = true;
    busy = true;
    final generation = ++_generation;
    try {
      final path = await _native.invokeMethod<String>('getRemoteIPCPath');
      if (path == null ||
          !path.endsWith('/yw.sock') ||
          utf8.encode(path).length >= 104) {
        throw const FormatException('Yinwei capture socket unavailable');
      }
      if (_disposed || generation != _generation) return;
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (_disposed || generation != _generation) return;
      if (type == FileSystemEntityType.link ||
          type == FileSystemEntityType.directory) {
        throw const FormatException('Unexpected capture endpoint');
      }
      if (type != FileSystemEntityType.notFound) await File(path).delete();
      if (_disposed || generation != _generation) return;
      _path = path;
      final server = await _bindIPC(path);
      if (_disposed || generation != _generation) {
        await server.close();
        try {
          if (await File(path).exists()) await File(path).delete();
        } catch (_) {}
        return;
      }
      _server = server;
      await _native.invokeMethod<void>('prepareRemoteReturn');
      if (_disposed || generation != _generation) return;
      inputChunks = receivedChunks =
          playedChunks = outputChunks = outputDrops = _writes = 0;
      _lastCapture = null;
      final startedAt = DateTime.now();
      active = true;
      _server!.listen((socket) {
        if (!active || generation != _generation || _capture != null) {
          socket.destroy();
          return;
        }
        _capture = socket;
        _connecting = true;
        // Wait for the native source before starting the five-second WSS
        // idle clock. Drop capture chunks during handshake, never queue them.
        _client!.start().then((_) {
          if (!active || generation != _generation) {
            _client?.stop();
            return;
          }
          _connecting = false;
        }).catchError((Object _) {
          if (active && generation == _generation) {
            unawaited(stop(
                message:
                    'Laptop transform unavailable · check Yinwei and sign in again'));
          }
        });
        final parser = IosCapturePCMParser((pcm, gap) {
          if (!active || generation != _generation) return;
          _lastCapture = DateTime.now();
          ++inputChunks;
          _client?.trySend(pcm, discontinuous: gap);
        });
        socket.listen((bytes) {
          if (!active || generation != _generation) return;
          try {
            parser.add(bytes);
          } catch (_) {
            unawaited(stop(
                message: 'Invalid captured audio packet · restart sharing'));
          }
        }, onDone: () {
          if (active && generation == _generation) {
            unawaited(stop(message: 'Capture stopped · start again'));
          }
        }, onError: (Object _) {
          if (active && generation == _generation) {
            unawaited(stop(message: 'Capture connection interrupted'));
          }
        });
      },
          onError: (Object _) =>
              unawaited(stop(message: 'Capture connection interrupted')));
      _statusTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (active &&
            _lastCapture == null &&
            DateTime.now().difference(startedAt) >
                const Duration(seconds: 30)) {
          unawaited(stop(
              message:
                  'No capture received · start Yinwei Music Audio and verify both signed bundles select the same App Group'));
        } else if (active &&
            _lastCapture != null &&
            DateTime.now().difference(_lastCapture!) >
                const Duration(seconds: 5)) {
          unawaited(stop(message: 'Capture stalled · restart audio sharing'));
        } else if (active) {
          _changed(inputChunks == 0
              ? 'Choose Yinwei in Apple’s sharing picker'
              : _connecting
                  ? 'Connecting live audio to laptop…'
                  : outputChunks == 0
                      ? 'Capture connected · waiting for processed return'
                      : playedChunks == 0
                          ? 'Processed audio received · waiting for iPad playback'
                          : 'iPad playback confirmed · receiving processed audio');
          unawaited(refreshOutputStatus());
        }
      });
      _changed('Choose Yinwei in Apple’s sharing picker');
      await _probe.showBroadcastPicker();
    } on PlatformException catch (error) {
      await stop(message: error.message ?? 'Native live audio unavailable');
    } on SocketException catch (_) {
      await stop(
          message:
              'Capture connection could not open · restart Yinwei and check App Group access');
    } on FileSystemException catch (_) {
      await stop(
          message:
              'Capture endpoint unavailable · check App Group access in this signed build');
    } on FormatException catch (error) {
      await stop(message: error.message);
    } catch (_) {
      await stop(
          message:
              'Live session could not start · check capture and laptop diagnostics');
    } finally {
      _operationInFlight = false;
      busy = _stopping != null;
      _changed();
    }
  }

  @visibleForTesting
  void acceptReturnAudio(Uint8List packet) {
    if (!active) return;
    ++receivedChunks;
    if (_writes >= 8) {
      ++outputDrops;
      return;
    }
    ++_writes;
    final generation = _generation;
    _native
        .invokeMapMethod<String, dynamic>('writeRemoteReturn', packet)
        .then((result) {
      if (generation != _generation) return;
      if (result?['accepted'] == true) {
        ++outputChunks;
      } else {
        ++outputDrops;
      }
    }).catchError((Object error) {
      if (generation == _generation) {
        unawaited(stop(
            message: error is PlatformException
                ? error.message ?? 'iPad audio output interrupted'
                : 'Could not deliver processed audio to iPad output'));
      }
    }).whenComplete(() {
      if (generation == _generation) --_writes;
    });
  }

  @visibleForTesting
  Future<void> refreshOutputStatus() async {
    if (!active || _pollingOutput) return;
    _pollingOutput = true;
    final generation = _generation;
    try {
      final result = await _native
          .invokeMapMethod<String, dynamic>('getRemoteReturnStatus');
      if (!active || generation != _generation) return;
      if (result?['ready'] == false) {
        await stop(
            message:
                'iPad output stopped · check your audio route and start again');
        return;
      }
      final played = result?['played'];
      if (played is int && played >= 0) playedChunks = played;
      _changed();
    } on PlatformException catch (error) {
      if (active && generation == _generation) {
        await stop(
            message: error.message ?? 'iPad playback diagnostics unavailable');
      }
    } finally {
      _pollingOutput = false;
    }
  }

  Future<void> stop({String? message}) {
    if (_stopping != null) return _stopping!;
    final completer = Completer<void>();
    _stopping = completer.future;
    busy = true;
    _cleanup(message).then((_) {
      _stopping = null;
      busy = _operationInFlight;
      _changed();
      completer.complete();
    }, onError: (Object error, StackTrace stack) {
      _stopping = null;
      busy = _operationInFlight;
      _changed();
      completer.completeError(error, stack);
    });
    return completer.future;
  }

  Future<void> _cleanup(String? message) async {
    ++_generation;
    active = false;
    _connecting = false;
    _statusTimer?.cancel();
    _statusTimer = null;
    _capture?.destroy();
    _capture = null;
    final server = _server;
    _server = null;
    final path = _path;
    _path = null;
    _client?.stop();
    await server?.close();
    try {
      await _native.invokeMethod<void>('stopRemoteReturn');
    } catch (_) {}
    if (path != null) {
      try {
        if (await File(path).exists()) await File(path).delete();
      } catch (_) {}
    }
    _writes = 0;
    _changed(message ??
        'Stopped · Music sharing may still be active in Control Center');
  }

  void _changed([String? message]) {
    if (message != null) status = message;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    _client?.dispose();
    super.dispose();
  }
}
