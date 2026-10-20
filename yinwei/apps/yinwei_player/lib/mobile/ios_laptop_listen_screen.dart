import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:yinwei_player/mobile/ios_listen_room_screen.dart';
import 'package:yinwei_player/platform/ios_laptop_listen_output.dart';
import 'package:yinwei_player/platform/listen_network_changes.dart';
import 'package:yinwei_player/remote/laptop_listen_controller.dart';
import 'package:yinwei_player/remote/saved_sign_in.dart';
import 'package:yinwei_player/remote/private_pair_store.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

LaptopListenController? _shared;

/// One listening session for the app: it keeps playing when this screen is
/// closed, Yinwei is in the background or the iPad is locked.
LaptopListenController sharedLaptopListen() =>
    _shared ??= LaptopListenController(
        output: IosLaptopListenOutput(),
        signInStore: KeychainSignInStore(),
        pairStore: KeychainPrivatePairStore(),
        networkChanges: listenNetworkChanges(),
        loadSoundQuality: () async {
          final file = await _soundQualityFile();
          return await file.exists() ? (await file.readAsString()).trim() : null;
        },
        saveSoundQuality: (quality) async =>
            (await _soundQualityFile()).writeAsString(quality, flush: true));

/// The chosen sound quality (High, Max or Lossless), kept between launches.
Future<File> _soundQualityFile() async => File(
    '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}listen_sound_quality');

/// "Listen to laptop": the laptop plays the music with Live Transfer, this
/// iPad plays the spatial result and controls the laptop (like the iPad web
/// page, but it keeps playing in the background and on the lock screen).
class IosLaptopListenScreen extends StatefulWidget {
  const IosLaptopListenScreen({super.key, this.player, this.session});

  /// The iPad's own file player; listening waits until it is paused.
  final EngineController? player;
  final LaptopListenController? session;

  @override
  State<IosLaptopListenScreen> createState() => _IosLaptopListenScreenState();
}

class _IosLaptopListenScreenState extends State<IosLaptopListenScreen>
    with WidgetsBindingObserver {
  late final LaptopListenController _session =
      widget.session ?? sharedLaptopListen();
  final _entry = TextEditingController(
      text: 'https://yinwei-remote-entry-01a12de8.yinwei-01a12de8.workers.dev/');
  final _username = TextEditingController();
  final _password = TextEditingController();
  // Slider values under the user's finger; sent when released.
  final _held = <String, double>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _entry.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _session.resumed();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: YinweiColors.background,
        appBar: AppBar(
            title: const Text('Listen to laptop'),
            backgroundColor: YinweiColors.background),
        body: AnimatedBuilder(
          animation: Listenable.merge(
              [_session, if (widget.player != null) widget.player!]),
          builder: (context, _) => ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _session.signedIn
                        ? _listening(context)
                        : _signIn(context),
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  List<Widget> _signIn(BuildContext context) => [
        Text('The laptop plays. This iPad listens.',
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 10),
        const Text(
            'Your laptop plays the music with spatial sound (Live Transfer). '
            'This iPad plays the result and keeps playing in the background '
            'and with the screen locked, with play, pause, next and previous '
            'on the lock screen.'),
        const SizedBox(height: 22),
        TextField(
            controller: _entry,
            enabled: !_session.busy,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'Yinwei entry link')),
        const SizedBox(height: 12),
        TextField(
            controller: _username,
            enabled: !_session.busy,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Owner account')),
        const SizedBox(height: 12),
        TextField(
            controller: _password,
            obscureText: true,
            enabled: !_session.busy,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Password')),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _session.busy
              ? null
              : () async {
                  try {
                    await _session.signIn(
                        _entry.text, _username.text.trim(), _password.text);
                  } finally {
                    _password.clear();
                  }
                },
          child: const Text('Sign in to laptop'),
        ),
        const SizedBox(height: 14),
        Semantics(liveRegion: true, child: Text(_session.status)),
        const SizedBox(height: 18),
        Text(
          'Your password is only sent to the laptop, never stored. The '
          'session stays in memory until you sign out or close Yinwei.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ];

  List<Widget> _listening(BuildContext context) {
    final s = _session;
    final state = s.snapshot ?? const <String, dynamic>{};
    final caps = _map(state['capabilities']);
    final liveInfo = _map(state['live']);
    final liveRunning = state['liveRunning'] == true;
    final remoteLive = caps['remoteLive'] == true;
    final liveMedia = caps['liveMedia'] == true;
    final control = s.hasControl && s.connected && !s.pending;
    final playing = liveRunning
        ? liveInfo['playing'] == true
        : _map(state['transport'])['playing'] == true;
    final localPlaying = widget.player?.playing == true;
    final text = Theme.of(context).textTheme;
    return [
      _card([
        Text(_musicLine(state), style: text.titleMedium),
        const SizedBox(height: 4),
        Text(
          [
            s.connected ? 'Connected to laptop' : 'Connecting to laptop…',
            liveRunning ? 'Live Transfer on' : 'Live Transfer off',
            if (s.listening)
              s.audioConnected ? 'playing here' : 'connecting audio…',
          ].join('  ·  '),
          style: text.bodySmall,
        ),
      ]),
      const SizedBox(height: 14),
      if (!s.listening)
        FilledButton(
          onPressed: s.busy || !s.connected || localPlaying
              ? null
              : () => s.startListening(startLive: remoteLive && !liveRunning),
          child: Text(remoteLive && !liveRunning
              ? 'Start on laptop and listen'
              : 'Listen on this iPad'),
        )
      else
        OutlinedButton(
            onPressed: () => s.stopListening(),
            child: const Text('Stop listening')),
      if (localPlaying && !s.listening) ...[
        const SizedBox(height: 6),
        Text('Pause the iPad’s own player first.', style: text.bodySmall),
      ],
      if (liveRunning && remoteLive) ...[
        const SizedBox(height: 6),
        TextButton(
            onPressed: control ? () => s.command('live.stop') : null,
            child: const Text('Stop Live on laptop')),
      ],
      const SizedBox(height: 10),
      Semantics(liveRegion: true, child: Text(s.status)),
      if (s.notice != null) ...[
        const SizedBox(height: 4),
        Text(s.notice!, style: text.bodySmall),
      ],
      const SizedBox(height: 18),
      if (!s.hasControl)
        Row(children: [
          OutlinedButton(
              onPressed: s.connected ? () => s.takeControl() : null,
              child: const Text('Take control')),
          const SizedBox(width: 12),
          Expanded(
              child: Text(
                  'Take control to change the music, position and mode.',
                  style: text.bodySmall)),
        ])
      else
        Text('You have control of the laptop.',
            style: text.bodySmall?.copyWith(color: YinweiColors.success)),
      const SizedBox(height: 12),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
              tooltip: 'Previous',
              iconSize: 34,
              onPressed:
                  control && liveMedia ? () => s.command('media.previous') : null,
              icon: const Icon(Icons.skip_previous_rounded)),
          const SizedBox(width: 18),
          IconButton.filled(
              tooltip: playing ? 'Pause' : 'Play',
              iconSize: 40,
              onPressed: control
                  ? () => s.command(liveMedia
                      ? (playing ? 'media.pause' : 'media.play')
                      : (playing ? 'pause' : 'play'))
                  : null,
              icon: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded)),
          const SizedBox(width: 18),
          IconButton(
              tooltip: 'Next',
              iconSize: 34,
              onPressed:
                  control && liveMedia ? () => s.command('media.next') : null,
              icon: const Icon(Icons.skip_next_rounded)),
        ],
      ),
      const SizedBox(height: 18),
      ..._spatial(context, state, control),
      const SizedBox(height: 22),
      if (s.listening)
        Text(
          'Audio: ${s.received} received · ${s.played} played · '
          'buffer ${s.bufferMs} ms · ${s.underruns} underruns · '
          '${s.dropped} dropped',
          style: text.bodySmall,
        ),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
            onPressed: s.busy ? null : () => s.signOut(),
            child: const Text('Sign out')),
      ),
    ];
  }

  List<Widget> _spatial(
      BuildContext context, Map<String, dynamic> state, bool control) {
    final caps = _map(state['capabilities']);
    final mode = _map(state['spatialMode']);
    final pose = _map(state['pose']);
    final stereo2 = mode['array'] == 'stereo2';
    final orbit = mode['motion'] == 'orbit';
    double value(String key, Object? laptop, double fallback) =>
        _held[key] ?? (laptop is num ? laptop.toDouble() : fallback);
    final az = value('az', pose['azimuthDeg'], 0);
    final el = value('el', pose['elevationDeg'], 0);
    final distance = value('distance', pose['distanceM'], 2);
    final orbitHz = value('orbitHz', mode['orbitHz'], 0.4);
    final pointControl = control && caps['pointControl'] == true;
    void sendPosition() => _send(['az', 'el', 'distance'], 'point.set', {
          'azimuthDeg': _held['az'] ?? az,
          'elevationDeg': _held['el'] ?? el,
          'distanceM': _held['distance'] ?? distance,
        });
    return [
      _card([
        if (caps['remoteArray'] == true) ...[
          SegmentedButton<String>(
            style: _segmentStyle,
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'point', label: Text('Point')),
              ButtonSegment(value: 'stereo2', label: Text('2.0')),
            ],
            selected: {stereo2 ? 'stereo2' : 'point'},
            onSelectionChanged: control
                ? (v) => _session.command('array.mode', {'mode': v.first})
                : null,
          ),
          const SizedBox(height: 10),
        ],
        SegmentedButton<String>(
          style: _segmentStyle,
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'fixed', label: Text('Fixed')),
            ButtonSegment(value: 'orbit', label: Text('Orbit')),
          ],
          selected: {orbit ? 'orbit' : 'fixed'},
          onSelectionChanged: control && !stereo2
              ? (v) => _session.command('motion.set', {
                    'motion': v.first,
                    if (v.first == 'orbit') 'orbitHz': orbitHz,
                  })
              : null,
        ),
        _slider('Orbit speed', '${orbitHz.toStringAsFixed(2)} Hz', 'orbitHz',
            orbitHz, 0.05, 2, 39, control && !stereo2 && orbit,
            () => _send(['orbitHz'], 'motion.set',
                {'motion': 'orbit', 'orbitHz': _held['orbitHz'] ?? orbitHz})),
        _slider('Azimuth', '${az.round()}°', 'az', az, -180, 180, 360,
            pointControl, sendPosition),
        _slider('Elevation', '${el.round()}°', 'el', el, -90, 90, 180,
            pointControl, sendPosition),
        _slider('Distance', '${distance.toStringAsFixed(1)} m', 'distance',
            distance, 0.5, 10, 95, pointControl, sendPosition),
      ]),
    ];
  }

  Widget _slider(String label, String shown, String key, double value,
          double min, double max, int divisions, bool enabled,
          VoidCallback send) =>
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(children: [
          SizedBox(width: 96, child: Text(label)),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged:
                  enabled ? (v) => setState(() => _held[key] = v) : null,
              onChangeEnd: enabled ? (_) => send() : null,
            ),
          ),
          SizedBox(
              width: 64, child: Text(shown, textAlign: TextAlign.right)),
        ]),
      );

  /// Sends the released slider values; laptop updates show again after.
  Future<void> _send(
      List<String> keys, String type, Map<String, dynamic> payload) async {
    try {
      await _session.command(type, payload);
    } finally {
      if (mounted) setState(() => keys.forEach(_held.remove));
    }
  }

  // Selected segment: a quiet accent fill with bright text, readable even
  // while the segment cannot be changed (no control yet).
  static final _segmentStyle = ButtonStyle(
    backgroundColor: WidgetStateProperty.resolveWith((states) =>
        states.contains(WidgetState.selected)
            ? YinweiColors.accent.withValues(alpha: 0.28)
            : Colors.transparent),
    foregroundColor: WidgetStateProperty.resolveWith((states) =>
        states.contains(WidgetState.selected)
            ? YinweiColors.textPrimary
            : states.contains(WidgetState.disabled)
                ? YinweiColors.textTertiary
                : YinweiColors.textSecondary),
    side: const WidgetStatePropertyAll(
        BorderSide(color: YinweiColors.hairlineStrong)),
  );

  Widget _card(List<Widget> children) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: YinweiColors.panel,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: YinweiColors.hairline),
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children),
      );

  static String _musicLine(Map<String, dynamic> state) {
    final live = _map(state['live']);
    final source = live['source'] is String ? live['source'] as String : '';
    if (source.isEmpty) return 'No music app open on the laptop';
    final title = live['title'] is String ? live['title'] as String : '';
    return title.isEmpty ? source : '$source · $title';
  }

  static Map<String, dynamic> _map(Object? value) =>
      value is Map<String, dynamic> ? value : const {};
}

/// Opens "Listen to laptop" from the iPad player: the Moonlight Room
/// ([IosListenRoomScreen]), which falls back to this classic screen when the
/// room can't run.
Future<void> openLaptopListen(BuildContext context, EngineController player) =>
    openListenRoom(context, player);
