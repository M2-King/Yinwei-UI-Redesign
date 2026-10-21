import 'dart:convert';
import 'dart:io';

import 'remote_protocol.dart';

typedef SodaLaunchIdentity = ({String command, List<String> runningPaths});

/// Dispatches one validated catalog track to the already-running Soda app.
/// No shell, media keys, playback polling or retry is used. Success only means
/// that the request was submitted; Soda still decides whether it can play it.
class SodaTrackLauncher {
  SodaTrackLauncher({
    Future<SodaLaunchIdentity> Function()? inspect,
    Future<void> Function(String executable, List<String> arguments)? launch,
    bool Function(String path)? exists,
    bool? supported,
  })  : _inspect = inspect ?? _inspectWindows,
        _launch = launch ?? _launchWindows,
        _exists = exists ?? ((path) => File(path).existsSync()),
        _supported = supported ?? Platform.isWindows;

  final Future<SodaLaunchIdentity> Function() _inspect;
  final Future<void> Function(String, List<String>) _launch;
  final bool Function(String) _exists;
  final bool _supported;

  Future<void> play(String trackId,
      {required void Function() beforeDispatch,
      Future<void> Function()? revalidateSelection}) async {
    if (!_supported) throw const RemoteFailure('soda_unavailable');
    final idMatch = RegExp(r'[0-9]{1,32}').matchAsPrefix(trackId);
    if (idMatch == null || idMatch.end != trackId.length) {
      throw const RemoteFailure('soda_invalid_selection');
    }
    SodaLaunchIdentity identity;
    try {
      identity = await _inspect();
    } catch (_) {
      throw const RemoteFailure('soda_handler_unavailable');
    }
    // This exact fixed template is the observed installed luna handler. Refuse
    // alternate flags, executables and substitutions rather than interpreting
    // a registry command line through a shell.
    final match = RegExp(r'^"([^"\r\n]+)" "--" "%1"$')
        .firstMatch(identity.command.trim());
    final executable = match?.group(1);
    if (executable == null ||
        !File(executable).isAbsolute ||
        executable.split(RegExp(r'[/\\]')).last.toLowerCase() !=
            'sodamusic.exe' ||
        !_exists(executable)) {
      throw const RemoteFailure('soda_handler_changed');
    }
    if (!identity.runningPaths
        .any((path) => path.toLowerCase() == executable.toLowerCase())) {
      throw const RemoteFailure('soda_not_running');
    }
    final uri = Uri(
      scheme: 'luna',
      host: 'luna.com',
      path: '/playing',
      queryParameters: {'track_id': trackId, 'media_type': 'track'},
    );
    // Registry inspection may wait for its helper. Fence account, catalog and
    // selection again after that wait, before the final synchronous lease guard.
    await revalidateSelection?.call();
    // Last synchronous guard after all account/catalog/registry preparation.
    // A refusal here is definitely before dispatch and can safely be reported.
    beforeDispatch();
    try {
      await _launch(executable, ['--', uri.toString()]);
    } catch (_) {
      // Never label an ambiguous external dispatch as a pre-action lease/state
      // refusal: clients must not repeat a possibly submitted playback action.
      throw const RemoteFailure('soda_dispatch_uncertain');
    }
  }

  static Future<SodaLaunchIdentity> _inspectWindows() async {
    const script = r'''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$key = Get-Item -LiteralPath 'Registry::HKEY_CLASSES_ROOT\luna\shell\open\command'
$paths = @(Get-Process -Name SodaMusic -ErrorAction SilentlyContinue | ForEach-Object { $_.Path } | Where-Object { $_ })
@{ command = $key.GetValue(''); runningPaths = $paths } | ConvertTo-Json -Compress
''';
    final bytes = <int>[];
    for (final unit in script.codeUnits) {
      bytes.addAll([unit & 255, unit >> 8]);
    }
    // The script is constant; no registry value or remote selection is ever
    // interpolated into PowerShell code.
    final process = await Process.start('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-EncodedCommand',
      base64Encode(bytes)
    ]);
    final stdout = utf8.decoder.bind(process.stdout).join();
    final stderr = process.stderr.drain<void>();
    try {
      final code = await process.exitCode.timeout(const Duration(seconds: 4));
      await stderr;
      final value = jsonDecode(await stdout);
      if (code != 0 ||
          value is! Map ||
          value['command'] is! String ||
          value['runningPaths'] is! List) {
        throw const FormatException('invalid_soda_handler');
      }
      return (
        command: value['command'] as String,
        runningPaths:
            (value['runningPaths'] as List).whereType<String>().toList()
      );
    } catch (_) {
      process.kill(); // Only our bounded read-only helper, never the music app.
      rethrow;
    }
  }

  static Future<void> _launchWindows(
      String executable, List<String> args) async {
    await Process.start(executable, args,
        mode: ProcessStartMode.detached, runInShell: false);
  }
}
