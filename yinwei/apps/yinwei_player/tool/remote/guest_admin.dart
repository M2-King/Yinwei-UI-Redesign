// Laptop-only administration of Yinwei friend (guest) accounts.
//
//   dart run tool/remote/guest_admin.dart --config <deployment.json> invite
//   dart run tool/remote/guest_admin.dart --config <deployment.json> list
//   dart run tool/remote/guest_admin.dart --config <deployment.json> revoke <username>
//
// It edits the guest store next to the owner account file in the private
// runtime directory. There is no network API for creating invites.
import 'dart:convert';
import 'dart:io';

import 'package:yinwei_player/remote/remote_guest.dart';
import 'package:yinwei_player/remote/remote_protocol.dart';

Future<void> main(List<String> args) async {
  final configIndex = args.indexOf('--config');
  if (configIndex < 0 || configIndex + 1 >= args.length) _usage();
  final rest = [...args]..removeRange(configIndex, configIndex + 2);
  if (rest.isEmpty) _usage();

  final config = jsonDecode(await File(args[configIndex + 1]).readAsString())
      as Map<String, dynamic>;
  final accountFile = config['ownerAccountFile'];
  if (accountFile is! String) {
    stderr.writeln('Deployment config has no ownerAccountFile.');
    exit(2);
  }
  final store = GuestStore(Directory(
      '${File(accountFile).parent.path}${Platform.pathSeparator}guests'));

  try {
    switch (rest.first) {
      case 'invite':
        final token = await store.createInvite();
        final origin = config['publicOrigin'];
        stdout
          ..writeln('One-time invite, valid for '
              '${guestInviteLifetime.inHours} hours. Send it privately:')
          ..writeln(origin is String && origin.isNotEmpty
              ? '$origin/remote/guest/invite#$token'
              : '<current Yinwei address>/remote/guest/invite#$token')
          ..writeln('The part after # is never sent to any server; '
              'the address changes when the laptop tunnel restarts.');
      case 'list':
        final accounts = await store.accounts();
        if (accounts.isEmpty) stdout.writeln('No friends yet.');
        for (final a in accounts) {
          stdout.writeln(
              '${a.username.padRight(20)} ${a.displayName.padRight(24)} '
              '${a.active ? 'active' : 'revoked ${a.revoked!.toLocal()}'}');
        }
      case 'revoke':
        if (rest.length != 2) _usage();
        stdout.writeln(await store.revoke(rest[1])
            ? 'Revoked ${rest[1]}. Their sessions end on their next request.'
            : 'No active friend named ${rest[1]}.');
      default:
        _usage();
    }
  } on RemoteFailure catch (error) {
    stderr.writeln('Refused: ${error.code}');
    exit(1);
  }
}

Never _usage() {
  stderr.writeln('usage: guest_admin.dart --config <deployment.json> '
      '(invite | list | revoke <username>)');
  exit(64);
}
