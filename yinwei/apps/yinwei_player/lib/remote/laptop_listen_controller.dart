import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'listen_quality.dart';
import 'remote_entry.dart';
import 'remote_owner_client.dart';
import 'saved_sign_in.dart';
import 'listen_audio_diagnostics.dart';

/// Plays the laptop's processed stereo on this device: the iPad's native
/// player in the app, a fake in tests.
abstract class LaptopListenOutput {
  /// Opens the output for listening. It holds the audio session (needed for
  /// lock-screen controls) and keeps playing in the background and while
  /// the screen is locked.
  Future<void> prepare();

  /// The laptop started a new stream (new epoch or sample rate): drop queued
  /// audio and play [sampleRate] from now on.
  Future<void> newStream(int sampleRate);

  /// Queues one YNW1 (PCM) or YNO1 (Opus) packet; false when it was dropped.
  Future<bool> write(Uint8List packet);

  /// True when this device can decode the laptop's Opus stream.
  Future<bool> supportsOpus();

  /// `ready`, `interrupted`, `played`, `underruns`, `bufferMs`, `queuedMs`.
  Future<Map<String, dynamic>> status();

  Future<void> stop();

  /// What the lock screen and Control Center show.
  Future<void> showNowPlaying(
      {required String title, required String artist, required bool playing});
  Future<void> hideNowPlaying();

  /// Lock-screen and Control Center buttons (`play`, `pause`, `toggle`,
  /// `next`, `previous`); null removes them.
  void setRemoteCommandHandler(void Function(String action)? handler);
}

/// The header fields of one laptop audio packet: YNW1 (float PCM) or YNO1
/// (the same header, then one 20 ms Opus packet).
class YnwPacketHeader {
  const YnwPacketHeader(this.epoch, this.sequence, this.sampleRate,
      {required this.firstFrame,
      required this.frames,
      required this.droppedChunks,
      this.opus = false});
  final int epoch, sequence, sampleRate;
  final int firstFrame, frames, droppedChunks;
  final bool opus;

  static YnwPacketHeader? parse(Uint8List packet) {
    if (packet.length < 57 || packet.length > 56 + 512 * 8) return null;
    final data = ByteData.sublistView(packet);
    final frames = data.getUint32(36, Endian.little);
    final rate = data.getUint32(32, Endian.little);
    if (data.getUint32(0, Endian.little) == ynoMagic) {
      if (data.getUint32(4, Endian.little) != 1 ||
          frames != listenOpusFrames ||
          rate != 48000 ||
          packet.length > 56 + 1500) {
        return null;
      }
      return YnwPacketHeader(data.getUint64(8, Endian.little),
          data.getUint64(16, Endian.little), rate,
          firstFrame: data.getUint64(24, Endian.little),
          frames: frames,
          droppedChunks: data.getUint32(44, Endian.little),
          opus: true);
    }
    if (data.getUint32(0, Endian.little) != ynwMagic ||
        data.getUint32(4, Endian.little) != 1 ||
        frames == 0 ||
        frames > 512 ||
        packet.length != 56 + frames * 8 ||
        rate < 8000 ||
        rate > 192000) {
      return null;
    }
    return YnwPacketHeader(data.getUint64(8, Endian.little),
        data.getUint64(16, Endian.little), rate,
        firstFrame: data.getUint64(24, Endian.little),
        frames: frames,
        droppedChunks: data.getUint32(44, Endian.little));
  }
}

/// "Listen to laptop": the laptop plays the music with Live Transfer and
/// this device plays the processed audio, also in the background and with
/// the screen locked. It controls the laptop with the same requests and
/// control-lease rules as the iPad web page.
class LaptopListenController extends ChangeNotifier {
  LaptopListenController({
    required this.output,
    Future<Uri> Function(String entry)? resolveEntry,
    RemoteOwnerClient Function(Uri origin)? clientFor,
    this.retryDelay = const Duration(seconds: 1),
    this.leaseRenewal = const Duration(seconds: 10),
    Future<String?> Function()? loadSoundQuality,
    this.saveSoundQuality,
    this.signInStore,
  })  : _resolveEntry = resolveEntry ?? resolveRemoteEntry,
        _clientFor =
            clientFor ?? ((origin) => RemoteOwnerClient(origin: origin)) {
    if (loadSoundQuality != null) {
      unawaited(loadSoundQuality().then((value) {
        final saved = ListenQuality.parse(value);
        if (saved != null && !_qualityTouched) soundQuality = saved;
      }, onError: (Object _) {}));
    }
  }

  final LaptopListenOutput output;
  final Future<void> Function(String quality)? saveSoundQuality;

  /// "Remember me on this iPad" (the Keychain in the app; null in tests
  /// that do not need it).
  final SignInStore? signInStore;

  /// Keep the next successful sign-in (the sign-in card's switch).
  bool rememberSignIn = true;

  /// The saved sign-in was tried once since the app started.
  bool autoSignInTried = false;
  bool _autoSigningIn = false;
  int _signBack = 0;
  final Future<Uri> Function(String) _resolveEntry;
  final RemoteOwnerClient Function(Uri) _clientFor;
  final Duration retryDelay, leaseRenewal;

  RemoteOwnerClient? _client;
  WebSocket? _events, _audio;
  Timer? _renewTimer, _statusTimer;
  final _wakes = <Completer<void>>{};
  String? _lease;
  bool _wantControl = false, _renewing = false, _polling = false;
  bool _disposed = false;
  int _session = 0, _listenGeneration = 0, _writes = 0;
  String _nowPlayingKey = '';

  bool busy = false,
      connected = false,
      listening = false,
      audioConnected = false,
      pending = false,
      interrupted = false;
  Map<String, dynamic>? snapshot;
  String status = 'Sign in to your laptop to listen here.';

  /// The result of the last control tap, if any.
  String? notice;

  /// `live` (Live Transfer) or `file` (the laptop's own player).
  String audioSource = '';

  /// The sound quality chosen here (Opus 320 kbit/s unless changed).
  ListenQuality soundQuality = ListenQuality.high;
  bool _qualityTouched = false;

  /// What the laptop is sending now; null until its audio is ready.
  ListenQuality? streamQuality;

  /// Both ends can do Opus: this device decodes it and the laptop sends it.
  /// Before the laptop answers, whether this device can.
  bool get opusAvailable => (_nativeOpus ?? false) && (_laptopOpus ?? true);
  bool? _nativeOpus, _laptopOpus;
  // The laptop understands quality changes on the open audio socket.
  bool _laptopQuality = false;
  int received = 0, dropped = 0, played = 0, underruns = 0;
  int bufferMs = 0, queuedMs = 0;
  final _audioClock = Stopwatch();
  var _diagnostics = ListenAudioDiagnostics();
  Map<String, dynamic> _nativeDiagnostics = const {};

  /// Export on demand; never send packet traces/percentiles through the room's
  /// per-frame UI bridge. The last 120 status samples cover about one minute.
  Map<String, Object?> audioDiagnostics() => {
        'schema': 1,
        'listening': listening,
        'audioConnected': audioConnected,
        'source': audioSource,
        'soundQuality': soundQuality.name,
        'streamQuality': streamQuality?.name,
        'elapsedMs': _audioClock.elapsedMilliseconds,
        'received': received,
        'played': played,
        'dropped': dropped,
        'inFlightWrites': _writes,
        'native': Map.of(_nativeDiagnostics),
        ..._diagnostics.snapshot(),
      };

  bool get signedIn => _client?.signedIn == true && snapshot != null;
  bool get hasControl => _lease != null;

  // ---------------------------------------------------------------- session

  Future<void> signIn(String entry, String username, String password) async {
    if (busy) return;
    busy = true;
    notice = null;
    _changed('Connecting to laptop…');
    await _endSession();
    final session = ++_session;
    try {
      final origin = await _resolveEntry(entry);
      if (session != _session) return;
      final client = _clientFor(origin);
      _client = client;
      final value = await client.signIn(username, password);
      if (session != _session) return;
      _applySnapshot(value['snapshot'] as Map<String, dynamic>);
      final store = signInStore;
      if (store != null) {
        unawaited((rememberSignIn
                ? store.save(SavedSignIn(
                    entry: entry, username: username, password: password))
                : store.clear())
            .catchError((Object _) {}));
      }
      _changed('Signed in · connecting to the laptop…');
      _renewTimer =
          Timer.periodic(leaseRenewal, (_) => unawaited(_renewLease()));
      unawaited(_eventsLoop(session));
    } catch (error) {
      if (session != _session) return;
      _client?.close();
      _client = null;
      snapshot = null;
      // The saved password no longer works (changed on the laptop): forget
      // it rather than retrying it.
      if (_autoSigningIn &&
          error is RemoteApiException &&
          error.statusCode == 401) {
        unawaited(forgetSavedSignIn());
      }
      _changed(_signInFailure(error));
    } finally {
      busy = false;
      _changed();
    }
  }

  static String _signInFailure(Object error) => switch (error) {
        RemoteEntryFailure(:final message) => message,
        RemoteApiException(statusCode: 401) =>
          'Owner account or password was rejected. Re-enter your laptop login.',
        RemoteApiException(statusCode: 429) =>
          'Too many sign-in attempts · wait a minute and try again.',
        RemoteApiException(:final statusCode) =>
          'Laptop connection failed (HTTP $statusCode) · check the laptop backend and try again.',
        TimeoutException() =>
          'Laptop connection timed out · check the laptop and network, then sign in again.',
        SocketException() =>
          'Cannot reach the laptop · check the internet connection and keep the laptop backend running.',
        HandshakeException() =>
          'Secure laptop connection failed · check the network and device date, then try again.',
        _ => 'Could not sign in. Check the laptop connection and owner login.',
      };

  /// The saved sign-in, if any (to fill the sign-in card).
  Future<SavedSignIn?> savedSignIn() async {
    try {
      return await signInStore?.load();
    } catch (_) {
      return null;
    }
  }

  Future<void> forgetSavedSignIn() async {
    try {
      await signInStore?.clear();
    } catch (_) {}
  }

  /// Signs in with the saved login; false when there is none.
  Future<bool> signInSaved() async {
    autoSignInTried = true;
    if (busy || signedIn) return false;
    final saved = await savedSignIn();
    if (saved == null || busy || signedIn) return false;
    _autoSigningIn = true;
    try {
      await signIn(saved.entry, saved.username, saved.password);
    } finally {
      _autoSigningIn = false;
    }
    return true;
  }

  /// The laptop forgot this iPad (its backend restarted): sign back in with
  /// the saved login while it comes back (about a minute), and listen again
  /// if this iPad was listening.
  Future<void> _signBackIn({required bool listen}) async {
    final generation = ++_signBack;
    for (final wait in const [1, 3, 5, 10, 15, 20, 30]) {
      await Future<void>.delayed(retryDelay * wait);
      if (_disposed || generation != _signBack) return;
      if (busy) continue;
      if (!signedIn && !await signInSaved()) return; // nothing saved
      if (signedIn) {
        if (listen && !listening && generation == _signBack) {
          await startListening();
        }
        return;
      }
    }
  }

  /// Sign out also forgets the saved sign-in.
  Future<void> signOut() async {
    ++_signBack;
    unawaited(forgetSavedSignIn());
    final client = _client;
    await stopListening();
    try {
      await client?.signOut();
    } catch (_) {}
    await _endSession();
    _changed('Signed out.');
  }

  /// The app is in the foreground again: reconnect now, not after backoff.
  void resumed() {
    for (final wake in _wakes.toList()) {
      if (!wake.isCompleted) wake.complete();
    }
    _wakes.clear();
  }

  Future<void> _endSession() async {
    await stopListening();
    ++_session;
    _renewTimer?.cancel();
    _renewTimer = null;
    final events = _events;
    _events = null;
    unawaited(events?.close(1000, 'signed_out'));
    _client?.close();
    _client = null;
    snapshot = null;
    connected = false;
    _lease = null;
    _wantControl = false;
    resumed();
  }

  bool _alive(int session) =>
      !_disposed && session == _session && _client != null;

  Future<void> _pause(int attempt) {
    final wake = Completer<void>();
    _wakes.add(wake);
    final delay = retryDelay * math.min(1 << math.min(attempt, 4), 10);
    return Future.any([Future<void>.delayed(delay), wake.future])
        .whenComplete(() => _wakes.remove(wake));
  }

  Future<void> _eventsLoop(int session) async {
    var attempt = 0;
    while (_alive(session)) {
      try {
        final socket = await _client!.openSocket('events');
        if (!_alive(session)) {
          unawaited(socket.close());
          return;
        }
        _events = socket;
        var sequence = 0;
        await for (final message in socket) {
          if (!_alive(session)) break;
          if (message is! String) continue;
          final data = jsonDecode(message);
          if (data is! Map ||
              data['type'] != 'snapshot' ||
              data['sequence'] is! int ||
              data['snapshot'] is! Map<String, dynamic> ||
              (data['sequence'] as int) <= sequence) {
            continue;
          }
          sequence = data['sequence'] as int;
          socket.add(jsonEncode({'ack': sequence}));
          attempt = 0;
          if (!connected) {
            connected = true;
            if (!listening) status = 'Connected to laptop.';
          }
          _applySnapshot(data['snapshot'] as Map<String, dynamic>);
        }
      } on RemoteApiException catch (error) {
        if (error.statusCode == 401) {
          if (_alive(session)) {
            final wasListening = listening;
            await _endSession();
            _changed(
                'The laptop signed this iPad out (it may have restarted) · '
                'sign in again.');
            if (signInStore != null) {
              unawaited(_signBackIn(listen: wasListening));
            }
          }
          return;
        }
      } catch (_) {
        // Network drop or laptop restart: retry below.
      }
      if (!_alive(session)) return;
      _events = null;
      if (connected) {
        connected = false;
        _lease = null;
        _changed('Laptop connection lost · reconnecting…');
      }
      await _pause(attempt++);
    }
  }

  void _applySnapshot(Map<String, dynamic> value) {
    snapshot = value;
    if (value['controlOwned'] != true && _lease != null) {
      // Either the laptop took over or this snapshot predates the lease. An
      // automatic re-take tells them apart: the laptop refuses it after a
      // takeover.
      _lease = null;
      if (_wantControl) unawaited(_renewLease());
    }
    _updateNowPlaying();
    _changed();
  }

  // ---------------------------------------------------------------- control

  /// The user's "Take control" tap.
  Future<bool> takeControl() async {
    final client = _client;
    if (client == null || !connected) return false;
    try {
      _lease = await client.lease();
      _wantControl = true;
      notice = null;
      return true;
    } on RemoteApiException catch (error) {
      notice = failureText(error.code);
      return false;
    } catch (_) {
      notice = 'The laptop did not answer · try again.';
      return false;
    } finally {
      _changed();
    }
  }

  /// Renews the lease, or re-takes control this device had (after a network
  /// drop or a lapse while iPadOS paused the app).
  Future<void> _renewLease() async {
    final client = _client;
    if (client == null || !connected || !_wantControl || _renewing || pending) {
      return;
    }
    _renewing = true;
    try {
      _lease = await client.lease(auto: true);
    } on RemoteApiException catch (error) {
      _lease = null;
      // The laptop or another device has control: wait for a tap here.
      if (error.code == 'control_taken' || error.code == 'control_busy') {
        _wantControl = false;
        notice = failureText(error.code);
      }
    } catch (_) {
      // Network blip: the next renewal tries again.
    } finally {
      _renewing = false;
      _changed();
    }
  }

  /// Sends a laptop command (`media.next`, `point.set`, `live.start`…).
  Future<bool> command(String type,
          [Map<String, dynamic> payload = const {}]) =>
      _command(type, payload, false);

  Future<bool> _command(
      String type, Map<String, dynamic> payload, bool retried) async {
    final client = _client, state = snapshot, lease = _lease;
    if (client == null ||
        state == null ||
        lease == null ||
        (pending && !retried)) {
      return false;
    }
    pending = true;
    _changed();
    try {
      final result = await client.command(state, lease, type, payload);
      if (result['snapshot'] is Map<String, dynamic>) {
        _applySnapshot(result['snapshot'] as Map<String, dynamic>);
      }
      notice = result['status'] == 'native_applied'
          ? 'Applied on the laptop.'
          : 'The laptop’s own controls superseded this change.';
      return true;
    } on RemoteApiException catch (error) {
      // The laptop's state moved on (a song change) or the lease lapsed:
      // refresh, re-take control and try once more.
      if (!retried &&
          (error.code == 'stale_state' || error.code == 'control_lost')) {
        try {
          if (error.code == 'control_lost') {
            _lease = await client.lease(auto: true);
          }
          _applySnapshot(
              (await client.session())['snapshot'] as Map<String, dynamic>);
          return await _command(type, payload, true);
        } catch (_) {
          // Report the original failure below.
        }
      }
      // A refusal about the music or the mode keeps control; anything else
      // needs control again.
      if (!const {
        'media_command_failed',
        'no_music_app',
        'music_not_playing',
        'music_app_open_failed',
        'music_app_no_song',
        'live_start_failed',
        'array_active',
        'invalid_payload',
        'stale_array',
        'speaker_limit',
        'speaker_protected',
        'array_inactive',
      }.contains(error.code)) {
        _lease = null;
      }
      notice = failureText(error.code);
      return false;
    } catch (_) {
      notice = 'The laptop did not answer · try again.';
      return false;
    } finally {
      pending = false;
      _changed();
    }
  }

  static String failureText(String code) => switch (code) {
        'stale_array' => 'The speakers changed. Select the speaker again.',
        'speaker_limit' => 'The room supports up to 8 speakers.',
        'speaker_protected' => 'The left and right speakers stay in the room.',
        'array_inactive' => 'Choose the 2.0 layout to place speakers.',
        'no_music_app' => 'Open your music app on the laptop first.',
        'music_not_playing' =>
          'The laptop music app did not start playing. Check it on the laptop.',
        'music_app_open_failed' =>
          'The laptop could not open its music app. Open it on the laptop.',
        'music_app_no_song' =>
          'The music app opened on the laptop but has no song ready. Choose a song there once.',
        'live_start_failed' =>
          'Live Transfer did not start on the laptop. Check the laptop.',
        'media_command_failed' =>
          'The laptop music app did not accept that command.',
        'array_active' => 'Orbit is off in 2.0 mode.',
        'local_busy' => 'The laptop is busy right now. Try again in a moment.',
        'control_busy' =>
          'Another device has control (the web page?). Try again when it is done.',
        'control_taken' =>
          'Someone at the laptop took control. Tap Take control to change things here.',
        _ =>
          'Change not applied: ${code.replaceAll('_', ' ')}. Take control again.',
      };

  /// A lock-screen or Control Center button.
  Future<void> remote(String action) async {
    if (!listening || _client == null) return;
    // A tap right after another one waits for it instead of being dropped.
    for (var i = 0; pending && i < 30; ++i) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (pending || snapshot == null) return;
    if (_lease == null && !await takeControl()) return;
    final state = snapshot!;
    final live = state['liveRunning'] == true;
    final capabilities = _map(state['capabilities']);
    final playing = live
        ? _map(state['live'])['playing'] == true
        : _map(state['transport'])['playing'] == true;
    final wanted = action == 'toggle' ? (playing ? 'pause' : 'play') : action;
    final type = switch (wanted) {
      // Not live yet: play starts the music and Live Transfer on the laptop.
      'play' when !live && capabilities['remoteLive'] == true => 'live.start',
      'play' ||
      'pause' ||
      'next' ||
      'previous' when capabilities['liveMedia'] == true =>
        'media.$wanted',
      // No music-app control: the laptop's own player.
      'play' || 'pause' => wanted,
      _ => null,
    };
    if (type != null) await command(type);
  }

  // -------------------------------------------------------------- listening

  /// Opens the iPad audio, takes control (lock-screen buttons need it) and
  /// streams the laptop's audio. [startLive]: also start the music and Live
  /// Transfer on the laptop, like the web page's "Start on laptop".
  Future<void> startListening({bool startLive = false}) async {
    if (!signedIn || listening || busy) return;
    busy = true;
    notice = null;
    _changed('Opening iPad audio…');
    try {
      await output.prepare();
    } catch (_) {
      busy = false;
      _changed(
          'Could not open iPad audio · close other audio apps and try again.');
      return;
    }
    listening = true;
    interrupted = false;
    received = dropped = played = underruns = bufferMs = queuedMs = 0;
    _diagnostics = ListenAudioDiagnostics();
    _nativeDiagnostics = const {};
    _audioClock
      ..reset()
      ..start();
    _writes = 0;
    _nowPlayingKey = '';
    final generation = ++_listenGeneration;
    output.setRemoteCommandHandler((action) => unawaited(remote(action)));
    _statusTimer = Timer.periodic(const Duration(milliseconds: 500),
        (_) => unawaited(_pollOutput(generation)));
    busy = false;
    _updateNowPlaying();
    _changed('Connecting laptop audio…');
    unawaited(_audioLoop(generation, _session));
    // Right after sign-in the event stream may still be connecting.
    for (var i = 0; !connected && listening && i < 30; ++i) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_lease == null && listening) await takeControl();
    if (startLive && snapshot?['liveRunning'] != true) {
      _changed('Starting the music and Live Transfer on the laptop…');
      await command('live.start');
    }
  }

  Future<void> stopListening({String? message}) async {
    if (!listening) return;
    listening = false;
    _audioClock.stop();
    audioConnected = false;
    interrupted = false;
    ++_listenGeneration;
    _statusTimer?.cancel();
    _statusTimer = null;
    final socket = _audio;
    _audio = null;
    unawaited(socket?.close(1000, 'stopped'));
    output.setRemoteCommandHandler(null);
    _writes = 0;
    try {
      await output.hideNowPlaying();
    } catch (_) {}
    try {
      await output.stop();
    } catch (_) {}
    _changed(message ?? 'Stopped listening · the laptop keeps playing.');
  }

  bool _listening(int generation, int session) =>
      listening && generation == _listenGeneration && _alive(session);

  Future<void> _audioLoop(int generation, int session) async {
    var attempt = 0;
    while (_listening(generation, session)) {
      String? reason;
      try {
        if (_nativeOpus == null) {
          try {
            _nativeOpus = await output.supportsOpus();
          } catch (_) {
            _nativeOpus = false;
          }
        }
        // Ask for a quality only when this device can play Opus; older
        // laptops ignore it and keep sending uncompressed audio.
        final socket = await _client!.openSocket('audio',
            hello: _nativeOpus == true ? {'quality': soundQuality.name} : null);
        if (!_listening(generation, session)) {
          unawaited(socket.close());
          return;
        }
        _audio = socket;
        _diagnostics.connectionOpened();
        int? epoch, rate;
        await for (final message in socket) {
          if (!_listening(generation, session)) break;
          if (message is String) {
            final data = jsonDecode(message);
            if (data is Map && data['type'] == 'audioReady') {
              audioConnected = true;
              attempt = 0;
              audioSource = data['source'] is String ? data['source'] : '';
              final codecs = data['codecs'];
              _laptopQuality = codecs is List;
              _laptopOpus = codecs is List && codecs.contains('opus');
              streamQuality = ListenQuality.parse(data['quality']) ??
                  ListenQuality.lossless;
              _changed(audioSource == 'live'
                  ? 'Listening · Live from the laptop'
                  : 'Listening · the laptop’s player');
            }
            continue;
          }
          if (message is! List<int>) continue;
          final packet =
              message is Uint8List ? message : Uint8List.fromList(message);
          final header = YnwPacketHeader.parse(packet);
          if (header == null) {
            ++_diagnostics.invalidPackets;
            ++dropped;
            continue;
          }
          _diagnostics.record(
              epoch: header.epoch,
              sequence: header.sequence,
              firstFrame: header.firstFrame,
              frames: header.frames,
              sampleRate: header.sampleRate,
              droppedChunks: header.droppedChunks,
              nowUs: _audioClock.elapsedMicroseconds);
          socket.add(jsonEncode({'ack': header.sequence}));
          // A late packet from before a flush on the laptop.
          if (epoch != null && header.epoch < epoch) {
            ++dropped;
            continue;
          }
          if (header.epoch != epoch || header.sampleRate != rate) {
            epoch = header.epoch;
            rate = header.sampleRate;
            await output.newStream(header.sampleRate);
            if (!_listening(generation, session)) break;
          }
          ++received;
          _write(packet, generation);
        }
        reason = socket.closeReason;
        streamQuality = null;
      } on RemoteApiException catch (error) {
        if (error.statusCode == 401) return; // The events loop signs out.
        reason = error.code;
      } catch (_) {
        // Network drop: retry below.
      }
      _audio = null;
      if (!_listening(generation, session)) return;
      audioConnected = false;
      _changed(switch (reason) {
        'audio_busy' =>
          'Another device is listening (Safari?) · stop it there. Retrying…',
        'live_stopped' => 'Live stopped on the laptop · waiting for its audio…',
        'audio_source_changed' => 'Laptop audio changed · reconnecting…',
        'unsupported_stream' =>
          'The laptop has no audio to send yet · retrying…',
        _ => 'Laptop audio interrupted · reconnecting…',
      });
      await _pause(attempt++);
    }
  }

  /// Changes the sound quality now (no reconnect when the laptop supports
  /// it) and remembers it for next time.
  void setSoundQuality(ListenQuality quality) {
    _qualityTouched = true;
    if (quality == soundQuality) return;
    soundQuality = quality;
    unawaited(saveSoundQuality?.call(quality.name).catchError((Object _) {}));
    final socket = _audio;
    if (socket != null && _laptopQuality && audioConnected) {
      final next = quality == ListenQuality.lossless || opusAvailable
          ? quality
          : ListenQuality.lossless;
      try {
        socket.add(jsonEncode({'quality': next.name}));
        streamQuality = next;
      } catch (_) {}
    }
    _changed();
  }

  void _write(Uint8List packet, int generation) {
    if (_writes >= 64 || interrupted) {
      if (interrupted) {
        ++_diagnostics.interruptedDrops;
      } else {
        ++_diagnostics.writeLimitDrops;
      }
      ++dropped;
      return;
    }
    ++_writes;
    final startedUs = _audioClock.elapsedMicroseconds;
    output.write(packet).then((accepted) {
      if (!accepted && generation == _listenGeneration) {
        ++dropped;
        ++_diagnostics.nativeRejected;
      }
    }, onError: (Object _) {
      if (generation == _listenGeneration) {
        ++dropped;
        ++_diagnostics.nativeRejected;
      }
    }).whenComplete(() {
      if (generation == _listenGeneration) {
        --_writes;
        _diagnostics
            .writeCompleted(_audioClock.elapsedMicroseconds - startedUs);
      }
    });
  }

  Future<void> _pollOutput(int generation) async {
    if (_polling || !listening || generation != _listenGeneration) return;
    _polling = true;
    try {
      final value = await output.status();
      if (!listening || generation != _listenGeneration) return;
      int number(String key) => value[key] is int ? value[key] as int : 0;
      played = number('played');
      underruns = number('underruns');
      bufferMs = number('bufferMs');
      queuedMs = number('queuedMs');
      // Allowlist numeric/route telemetry; never export arbitrary native fields.
      _nativeDiagnostics = {
        for (final key in const [
          'received',
          'accepted',
          'played',
          'queued',
          'ready',
          'underruns',
          'bufferMs',
          'queuedMs',
          'buffering',
          'sampleRate',
          'hardwareSampleRate',
          'ioBufferMs',
          'outputLatencyMs',
          'presentationLatencyMs',
          'outputRoute',
          'capacityDrops',
          'completionBacklogDrops',
          'configurationChanges',
          'maxRenderCheckGapMs',
          'interrupted',
        ])
          if (value.containsKey(key)) key: value[key]
      };
      _diagnostics.sampleBuffer(
          nowUs: _audioClock.elapsedMicroseconds,
          queuedMs: queuedMs,
          targetMs: bufferMs,
          underruns: underruns,
          dropped: dropped);
      final wasInterrupted = interrupted;
      interrupted = value['interrupted'] == true;
      if (value['ready'] == false && !interrupted) {
        await stopListening(
            message: 'iPad audio stopped (another app took over the sound) · '
                'tap Listen to continue.');
        return;
      }
      _changed(interrupted == wasInterrupted
          ? null
          : interrupted
              ? 'Paused by iPadOS (a call or another app) · resumes when it ends.'
              : 'Listening again.');
    } catch (_) {
      // Diagnostics only.
    } finally {
      _polling = false;
    }
  }

  void _updateNowPlaying() {
    final state = snapshot;
    if (!listening || state == null) return;
    final live = state['liveRunning'] == true;
    final liveInfo = _map(state['live']), track = _map(state['track']);
    final title = live
        ? _text(liveInfo['title'], 'Laptop music')
        : _text(track['title'], 'Yinwei laptop');
    final source =
        live ? _text(liveInfo['source'], '') : _text(track['artist'], '');
    final artist = source.isEmpty ? 'Yinwei laptop' : '$source · Yinwei laptop';
    final playing = live
        ? liveInfo['playing'] == true
        : _map(state['transport'])['playing'] == true;
    final key = jsonEncode([title, artist, playing]);
    if (key == _nowPlayingKey) return;
    _nowPlayingKey = key;
    unawaited(output
        .showNowPlaying(title: title, artist: artist, playing: playing)
        .catchError((Object _) {}));
  }

  static Map<String, dynamic> _map(Object? value) =>
      value is Map<String, dynamic> ? value : const {};
  static String _text(Object? value, String fallback) =>
      value is String && value.trim().isNotEmpty ? value : fallback;

  void _changed([String? message]) {
    if (message != null) status = message;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_endSession());
    _disposed = true;
    super.dispose();
  }
}
