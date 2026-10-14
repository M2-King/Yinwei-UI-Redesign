import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yinwei_player/update/release_manifest.dart';
import 'package:yinwei_player/update/update_check_service.dart';
import 'package:yinwei_player/update/update_policy.dart';

/// A manual Windows update check. Playback remains untouched while it is open.
class UpdateCheckDialog extends StatelessWidget {
  const UpdateCheckDialog({
    super.key,
    required this.installed,
    required this.check,
    required this.service,
  });

  final InstalledApp installed;
  final Future<UpdateDecision> check;
  final UpdateCheckService service;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Check for updates'),
      content: SizedBox(
        width: 430,
        child: FutureBuilder<UpdateDecision>(
          future: check,
          builder: (context, snapshot) {
            if (!snapshot.hasData && !snapshot.hasError) {
              return const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 18),
                  Text('Checking the stable channel…'),
                ],
              );
            }
            if (snapshot.hasError) {
              return Text('Could not check for updates. ${snapshot.error}');
            }
            final decision = snapshot.data!;
            if (!decision.updateAvailable) {
              final message = decision.reason == 'already_current'
                  ? 'Version ${installed.version} is up to date on the stable channel.'
                  : 'No compatible update is available (${decision.reason}).';
              return Text(message);
            }
            final release = decision.candidate!;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Version ${release.version} is available for Windows.'),
                const SizedBox(height: 10),
                if (release.notes.isNotEmpty) Text(release.notes),
                const SizedBox(height: 14),
                const Text(
                    'Download and install manually. The app will not install it automatically.'),
                const SizedBox(height: 10),
                const Text('Package SHA-256',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                SelectableText(release.sha256),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FutureBuilder<UpdateDecision>(
          future: check,
          builder: (context, snapshot) {
            if (!snapshot.hasData || !snapshot.data!.updateAvailable) {
              return const SizedBox.shrink();
            }
            final release = snapshot.data!.candidate!;
            final uri = service.packageUriFor(release);
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: uri.toString()),
                  ),
                  child: const Text('Copy link'),
                ),
                FilledButton(
                  onPressed: () async {
                    try {
                      await Process.start(
                        'explorer.exe',
                        [uri.toString()],
                        mode: ProcessStartMode.detached,
                      );
                    } catch (error) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                            content:
                                Text('Could not open download link: $error')),
                      );
                    }
                  },
                  child: const Text('Open download'),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}
