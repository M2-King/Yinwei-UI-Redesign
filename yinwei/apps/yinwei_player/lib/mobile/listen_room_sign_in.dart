import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yinwei_player/remote/laptop_listen_controller.dart';
import 'package:yinwei_player/remote/saved_sign_in.dart';

/// The Listen Room's sign-in, native so the password never enters the page.
/// With "Remember me on this iPad" the app signs in by itself next time
/// (the login is kept in this iPad's Keychain):
/// the approved prototype's glass card over a still picture of the room, with
/// the same fields and messages as the classic screen. A wrong password shows
/// in red; an unreachable laptop shows an amber note and "Try again".
class ListenRoomSignIn extends StatefulWidget {
  const ListenRoomSignIn({super.key, required this.session, this.onClose});

  final LaptopListenController session;
  final VoidCallback? onClose;

  /// The fixed entry bookmark (the same default as the classic screen).
  static const defaultEntry =
      'https://yinwei-remote-entry-01a12de8.yinwei-01a12de8.workers.dev/';

  @override
  State<ListenRoomSignIn> createState() => _ListenRoomSignInState();
}

enum _Outcome { none, wrongPassword, rejected, unreachable }

class _ListenRoomSignInState extends State<ListenRoomSignIn> {
  final _entry = TextEditingController(text: ListenRoomSignIn.defaultEntry);
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();
  bool _tried = false;
  SavedSignIn? _saved;

  LaptopListenController get _s => widget.session;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  /// Fills in the saved login and, once per app start, signs in with it.
  Future<void> _restore() async {
    final saved = await _s.savedSignIn();
    if (!mounted || saved == null) return;
    setState(() {
      _saved = saved;
      _entry.text = saved.entry;
      _username.text = saved.username;
    });
    if (_s.autoSignInTried || _s.busy || _s.signedIn) return;
    setState(() => _tried = true);
    await _s.signInSaved();
    if (!mounted) return;
    // A rejected saved password was forgotten: ask for it.
    if (_outcome == _Outcome.wrongPassword) setState(() => _saved = null);
  }

  /// The saved password stands in for an empty field, for the same login.
  String? get _savedPassword {
    final saved = _saved;
    return saved != null &&
            saved.entry == _entry.text.trim() &&
            saved.username == _username.text.trim()
        ? saved.password
        : null;
  }

  @override
  void dispose() {
    _entry.dispose();
    _username.dispose();
    _password.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  /// What the last sign-in attempt said, from the session's own messages.
  _Outcome get _outcome {
    if (!_tried || _s.busy || _s.signedIn) return _Outcome.none;
    final status = _s.status;
    if (status.startsWith('Owner account or password was rejected')) {
      return _Outcome.wrongPassword;
    }
    if (status.startsWith('Too many sign-in attempts')) {
      return _Outcome.rejected;
    }
    if (status.startsWith('Signed out') ||
        status.startsWith('Sign in to your laptop')) {
      return _Outcome.none;
    }
    return _Outcome.unreachable;
  }

  Future<void> _signIn() async {
    final password =
        _password.text.isNotEmpty ? _password.text : _savedPassword;
    if (password == null) {
      _passwordFocus.requestFocus();
      return;
    }
    setState(() => _tried = true);
    try {
      await _s.signIn(_entry.text.trim(), _username.text.trim(), password);
    } finally {
      _password.clear();
      TextInput.finishAutofillContext();
    }
    if (mounted && _outcome == _Outcome.wrongPassword) {
      setState(() => _saved = null);
      _passwordFocus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          key: const Key('listen-room-sign-in'),
          backgroundColor: _Look.night,
          body: Stack(
            fit: StackFit.expand,
            children: [
              Image.asset('assets/listen_room/room-still.jpg',
                  fit: BoxFit.cover, excludeFromSemantics: true),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    radius: 0.9,
                    colors: [Color(0x1F05070D), Color(0xA805070D)],
                  ),
                ),
              ),
              SafeArea(
                child: AnimatedBuilder(
                  animation: _s,
                  builder: (context, _) => Stack(children: [
                    Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: _card(context),
                      ),
                    ),
                    if (widget.onClose != null)
                      Positioned(
                        left: 12,
                        top: 8,
                        child: IconButton(
                          tooltip: 'Back to the player',
                          color: _Look.text,
                          onPressed: widget.onClose,
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                      ),
                  ]),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _card(BuildContext context) {
    final outcome = _outcome;
    final busy = _s.busy;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            padding: const EdgeInsets.fromLTRB(32, 32, 32, 24),
            decoration: BoxDecoration(
              color: _Look.glass,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: _Look.rim),
            ),
            child: AutofillGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    const Text('Yinwei',
                        style: TextStyle(
                            color: _Look.text,
                            fontSize: 32,
                            fontWeight: FontWeight.w300)),
                    Container(
                        width: 1,
                        height: 26,
                        margin: const EdgeInsets.symmetric(horizontal: 16),
                        color: _Look.rimStrong),
                    const Flexible(
                      child: Text('Moonlight Room',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: _Look.text2,
                              fontSize: 17,
                              fontWeight: FontWeight.w300)),
                    ),
                  ]),
                  const SizedBox(height: 24),
                  const Text('Listen to your laptop, anywhere in the house.',
                      style: TextStyle(
                          color: _Look.text,
                          fontSize: 22,
                          height: 1.25,
                          fontWeight: FontWeight.w300)),
                  const SizedBox(height: 8),
                  const Text(
                      'The laptop plays the music with spatial sound. This iPad '
                      'plays it back, even with the screen locked.',
                      style: TextStyle(
                          color: _Look.text2,
                          fontSize: 15,
                          height: 1.4,
                          fontWeight: FontWeight.w300)),
                  const SizedBox(height: 24),
                  _fields(
                    bad: outcome == _Outcome.wrongPassword,
                    children: [
                      _field(
                          Icons.person_outline_rounded,
                          'Owner account',
                          TextField(
                            controller: _username,
                            enabled: !busy,
                            autocorrect: false,
                            enableSuggestions: false,
                            autofillHints: const [AutofillHints.username],
                            textInputAction: TextInputAction.next,
                            style: _Look.input,
                            decoration: _Look.bare,
                          )),
                      _field(
                          Icons.lock_outline_rounded,
                          'Password',
                          TextField(
                            controller: _password,
                            focusNode: _passwordFocus,
                            enabled: !busy,
                            obscureText: true,
                            autocorrect: false,
                            enableSuggestions: false,
                            autofillHints: const [AutofillHints.password],
                            textInputAction: TextInputAction.go,
                            onSubmitted: (_) => _signIn(),
                            style: _Look.input,
                            decoration: _Look.bare.copyWith(
                                hintText: _saved != null
                                    ? 'Saved on this iPad'
                                    : 'Laptop owner password',
                                hintStyle: const TextStyle(color: _Look.text3)),
                          )),
                    ],
                  ),
                  Row(children: [
                    const Expanded(
                      child: Text('Remember me on this iPad',
                          style: TextStyle(color: _Look.text2, fontSize: 14)),
                    ),
                    Switch.adaptive(
                      key: const Key('listen-room-remember'),
                      value: _s.rememberSignIn,
                      activeTrackColor: const Color(0xFF6F9BFF),
                      onChanged: busy
                          ? null
                          : (on) {
                              setState(() => _s.rememberSignIn = on);
                              if (!on) {
                                _saved = null;
                                _s.forgetSavedSignIn();
                              }
                            },
                    ),
                  ]),
                  Theme(
                    data: Theme.of(context)
                        .copyWith(dividerColor: Colors.transparent),
                    // Its own ink layer, so the tap ripple shows on the glass.
                    child: Material(
                      type: MaterialType.transparency,
                      child: ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        childrenPadding: const EdgeInsets.only(bottom: 4),
                        iconColor: _Look.blueHi,
                        collapsedIconColor: _Look.blueHi,
                        title: const Text('Connection settings',
                            style:
                                TextStyle(color: _Look.blueHi, fontSize: 13)),
                        children: [
                          _fields(children: [
                            _field(
                                null,
                                'Yinwei entry link',
                                TextField(
                                  controller: _entry,
                                  enabled: !busy,
                                  autocorrect: false,
                                  keyboardType: TextInputType.url,
                                  style: _Look.input.copyWith(fontSize: 15),
                                  decoration: _Look.bare,
                                )),
                          ]),
                        ],
                      ),
                    ),
                  ),
                  if (outcome == _Outcome.wrongPassword ||
                      outcome == _Outcome.rejected)
                    Semantics(
                      liveRegion: true,
                      child: Row(children: [
                        const Icon(Icons.error_outline_rounded,
                            size: 18, color: _Look.error),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(
                                outcome == _Outcome.wrongPassword
                                    ? 'That password didn’t work. Use the owner password set on your laptop.'
                                    : _s.status,
                                style: const TextStyle(
                                    color: _Look.error, fontSize: 13))),
                      ]),
                    ),
                  if (outcome == _Outcome.unreachable)
                    Semantics(
                      liveRegion: true,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                        decoration: BoxDecoration(
                          color: const Color(0x14FFB15C),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0x47FFB15C)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.wifi_off_rounded,
                                size: 20, color: _Look.warn),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text.rich(
                                TextSpan(children: [
                                  const TextSpan(
                                      text:
                                          'Can’t reach your laptop right now. ',
                                      style: TextStyle(
                                          color: _Look.text,
                                          fontWeight: FontWeight.w500)),
                                  TextSpan(text: _s.status),
                                ]),
                                style: const TextStyle(
                                    color: _Look.text2, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 52,
                    child: FilledButton(
                      key: const Key('listen-room-sign-in-button'),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0x666989C8),
                        disabledBackgroundColor: const Color(0x406989C8),
                        foregroundColor: _Look.text,
                        disabledForegroundColor: _Look.text2,
                        shape: const StadiumBorder(
                            side: BorderSide(color: Color(0x99A0BEFF))),
                      ),
                      onPressed: busy ? null : _signIn,
                      child: busy
                          ? const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: _Look.text)),
                                SizedBox(width: 10),
                                Text('Signing in…'),
                              ],
                            )
                          : Text(
                              outcome == _Outcome.unreachable
                                  ? 'Try again'
                                  : 'Sign in',
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w500)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                      _s.rememberSignIn
                          ? 'Kept only in this iPad’s Keychain and sent only to '
                              'your laptop. Sign out to forget it.'
                          : 'Your password goes only to your laptop and is never '
                              'stored on this iPad.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: _Look.text3, fontSize: 12)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fields({bool bad = false, required List<Widget> children}) =>
      Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: const Color(0x40000000),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: bad ? const Color(0x8CFF8A8A) : _Look.rim),
        ),
        child: Column(children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(height: 1, color: _Look.rim),
            children[i],
          ],
        ]),
      );

  Widget _field(IconData? icon, String label, Widget input) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
        child: Row(children: [
          if (icon != null) ...[
            Icon(icon, size: 20, color: _Look.text3),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(color: _Look.text3, fontSize: 12)),
                input,
              ],
            ),
          ),
        ]),
      );
}

/// The room's colours (ui.css), for the native sign-in.
abstract final class _Look {
  static const night = Color(0xFF070A12);
  static const glass = Color(0xAD121724); // rgba(18, 23, 36, 0.68)
  static const rim = Color(0x1AC8D7FF);
  static const rimStrong = Color(0x33C8D7FF);
  static const text = Color(0xFFEEF1F8);
  static const text2 = Color(0xB8E2E8F6); // 0.72
  static const text3 = Color(0x94E2E8F6); // 0.58
  static const blueHi = Color(0xFFA9C3FF);
  static const warn = Color(0xFFFFB15C);
  static const error = Color(0xFFFF8A8A);
  static const input =
      TextStyle(color: text, fontSize: 17, fontWeight: FontWeight.w300);
  static const bare = InputDecoration(
      isDense: true,
      border: InputBorder.none,
      contentPadding: EdgeInsets.symmetric(vertical: 4));
}
