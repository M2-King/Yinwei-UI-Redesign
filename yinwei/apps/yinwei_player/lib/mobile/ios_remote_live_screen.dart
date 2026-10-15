import 'dart:async';
import 'package:flutter/material.dart';
import 'package:yinwei_player/platform/ios_remote_live_session.dart';
import 'package:yinwei_player/platform/replaykit_audio_probe.dart';
import 'package:yinwei_player/state/engine_controller.dart';
import 'package:yinwei_player/theme/yinwei_theme.dart';

/// Initial live listening surface. Laptop spatial settings remain authoritative;
/// the existing local iPad spatial workspace is not presented as remote control.
class IosRemoteLiveScreen extends StatefulWidget {
  const IosRemoteLiveScreen(
      {super.key, this.controller, this.probe, this.session});
  final EngineController? controller;
  final ReplayKitAudioProbe? probe;
  final IosRemoteLiveSession? session;
  @override
  State<IosRemoteLiveScreen> createState() => _IosRemoteLiveScreenState();
}

class _IosRemoteLiveScreenState extends State<IosRemoteLiveScreen>
    with WidgetsBindingObserver {
  late final IosRemoteLiveSession _session;
  final _entry = TextEditingController(
      text:
          'https://yinwei-remote-entry-01a12de8.yinwei-01a12de8.workers.dev/');
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _feedback = false, _dryRoute = false, _restart = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session = widget.session ?? IosRemoteLiveSession(probe: widget.probe);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.session == null) _session.dispose();
    _entry.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_session.stop(
          message:
              'Listening suspended · keep Yinwei visible and Start again'));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: YinweiColors.background,
        appBar: AppBar(
            title: const Text('Live listening'),
            backgroundColor: YinweiColors.background),
        body: AnimatedBuilder(
            animation: _session,
            builder: (context, _) =>
                ListView(padding: const EdgeInsets.all(24), children: [
                  Center(
                      child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 640),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                    'Music on iPad. Spatial processing on laptop.',
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall),
                                const SizedBox(height: 12),
                                const Text(
                                    'Keep Yinwei visible beside Music for this first live test. '
                                    'Set spatial position and processing mode on the laptop. '
                                    'The iPad plays the returned stereo audio.'),
                                const SizedBox(height: 24),
                                TextField(
                                    controller: _entry,
                                    enabled: !_session.busy && !_session.active,
                                    autocorrect: false,
                                    keyboardType: TextInputType.url,
                                    decoration: const InputDecoration(
                                        labelText: 'Yinwei entry link')),
                                const SizedBox(height: 12),
                                TextField(
                                    controller: _username,
                                    enabled: !_session.busy && !_session.active,
                                    autocorrect: false,
                                    enableSuggestions: false,
                                    decoration: const InputDecoration(
                                        labelText: 'Owner account')),
                                const SizedBox(height: 12),
                                TextField(
                                    controller: _password,
                                    obscureText: true,
                                    enabled: !_session.busy && !_session.active,
                                    autocorrect: false,
                                    enableSuggestions: false,
                                    decoration: const InputDecoration(
                                        labelText: 'Password')),
                                const SizedBox(height: 12),
                                FilledButton(
                                    onPressed: _session.busy || _session.active
                                        ? null
                                        : () async {
                                            try {
                                              await _session.signIn(
                                                  _entry.text,
                                                  _username.text.trim(),
                                                  _password.text);
                                            } finally {
                                              _password.clear();
                                            }
                                          },
                                    child: const Text('Sign in to laptop')),
                                const SizedBox(height: 24),
                                const Text(
                                    'Before live audio, confirm these tests on this iPad and headphone route.'),
                                CheckboxListTile(
                                    contentPadding: EdgeInsets.zero,
                                    value: _feedback,
                                    onChanged: _session.active
                                        ? null
                                        : (v) => setState(
                                            () => _feedback = v ?? false),
                                    title: const Text(
                                        'With Music paused, the return tone did not produce non-silent captured audio.')),
                                CheckboxListTile(
                                    contentPadding: EdgeInsets.zero,
                                    value: _dryRoute,
                                    onChanged: _session.active
                                        ? null
                                        : (v) => setState(
                                            () => _dryRoute = v ?? false),
                                    title: const Text(
                                        'My output route avoids hearing original Music together with the processed return.')),
                                CheckboxListTile(
                                    contentPadding: EdgeInsets.zero,
                                    value: _restart,
                                    onChanged: _session.active
                                        ? null
                                        : (v) => setState(
                                            () => _restart = v ?? false),
                                    title: const Text(
                                        'Music capture resumes after stopping, starting and changing tracks.')),
                                const SizedBox(height: 16),
                                FilledButton(
                                    onPressed: !_session.signedIn ||
                                            _session.busy ||
                                            _session.active ||
                                            !_feedback ||
                                            !_dryRoute ||
                                            !_restart ||
                                            widget.controller?.playing == true
                                        ? null
                                        : () => _session.start(
                                            routingVerified: true),
                                    child: const Text('Start live transform')),
                                OutlinedButton(
                                    onPressed: _session.active || _session.busy
                                        ? () => _session.stop()
                                        : null,
                                    child: const Text('Stop live transform')),
                                const SizedBox(height: 16),
                                Semantics(
                                    liveRegion: true,
                                    child: Text(_session.status)),
                                const SizedBox(height: 8),
                                Text(
                                    'Capture: ${_session.inputChunks} · Return: ${_session.outputChunks} '
                                    '· Output drops: ${_session.outputDrops}'),
                                const SizedBox(height: 16),
                                const Text(
                                    'Your owner password and session stay in memory. Closing this screen stops live listening. '
                                    'To end Apple’s broadcast too, use Stop Sharing in Control Center.'),
                              ]))),
                ])),
      );
}
