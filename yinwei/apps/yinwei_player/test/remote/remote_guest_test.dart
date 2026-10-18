import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/bridge/mock_engine.dart';
import 'package:yinwei_player/remote/remote_auth.dart';
import 'package:yinwei_player/remote/remote_gateway.dart';
import 'package:yinwei_player/remote/remote_guest.dart';
import 'package:yinwei_player/remote/remote_protocol.dart';
import 'package:yinwei_player/runtime/spatial_runtime_adapter.dart';
import 'package:yinwei_player/state/app_session_coordinator.dart';
import 'package:yinwei_player/state/engine_controller.dart';

// Low-cost PBKDF2 for tests only; production keeps the owner's cost.
GuestStore lowCostStore(Directory dir, {DateTime Function()? now}) =>
    GuestStore(dir, iterations: 10, minIterations: 10, now: now);

const friendPassword = 'friend-password-123';

void main() {
  late Directory dir;
  setUp(() async =>
      dir = await Directory.systemTemp.createTemp('yinwei-guests-'));
  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  group('GuestStore', () {
    test('invite tokens are stored only as hashes and work once', () async {
      final store = lowCostStore(dir);
      final token = await store.createInvite();
      final file = File('${dir.path}${Platform.pathSeparator}guests.json');
      expect(file.readAsStringSync(), isNot(contains(token)));
      expect(await store.inviteValid(token), isTrue);

      final account = await store.acceptInvite(
          token: token,
          username: 'mei',
          displayName: 'Mei',
          password: friendPassword);
      expect(account.active, isTrue);
      expect(file.readAsStringSync(), isNot(contains(friendPassword)));
      expect(await store.inviteValid(token), isFalse);
      await expectLater(
          store.acceptInvite(
              token: token,
              username: 'other',
              displayName: 'Other',
              password: friendPassword),
          throwsA(isA<RemoteFailure>()
              .having((e) => e.code, 'code', 'invalid_invite')));
    });

    test('invites expire after 24 hours', () async {
      var now = DateTime.utc(2026, 10, 18, 12);
      final store = lowCostStore(dir, now: () => now);
      final token = await store.createInvite();
      now = now.add(const Duration(hours: 24, seconds: 1));
      expect(await store.inviteValid(token), isFalse);
    });

    test('usernames are unique ignoring case; details are validated', () async {
      final store = lowCostStore(dir);
      await store.acceptInvite(
          token: await store.createInvite(),
          username: 'Mei',
          displayName: 'Mei',
          password: friendPassword);
      await expectLater(
          store.acceptInvite(
              token: await store.createInvite(),
              username: 'mei',
              displayName: 'Mei 2',
              password: friendPassword),
          throwsA(isA<RemoteFailure>()
              .having((e) => e.code, 'code', 'username_taken')));
      for (final bad in [
        ('a', 'Name', friendPassword), // username too short
        ('ok_name', '', friendPassword), // empty display name
        ('ok_name', 'Name', 'short'), // password too short
        ('bad name', 'Name', friendPassword), // space in username
      ]) {
        await expectLater(
            store.acceptInvite(
                token: await store.createInvite(),
                username: bad.$1,
                displayName: bad.$2,
                password: bad.$3),
            throwsA(isA<RemoteFailure>()
                .having((e) => e.code, 'code', 'invalid_account_details')));
      }
    });

    test('open invites are capped', () async {
      final store = lowCostStore(dir);
      for (var i = 0; i < guestMaxOpenInvites; ++i) {
        await store.createInvite();
      }
      await expectLater(store.createInvite(), throwsA(isA<RemoteFailure>()));
    });
  });

  group('GuestAuth', () {
    test('sign-in checks password, unknown users and revocation', () async {
      final store = lowCostStore(dir);
      await store.acceptInvite(
          token: await store.createInvite(),
          username: 'mei',
          displayName: 'Mei',
          password: friendPassword);
      final auth = GuestAuth(store);
      for (final attempt in [
        ('mei', 'wrong-password-000'),
        ('nobody', friendPassword)
      ]) {
        await expectLater(
            auth.signin(attempt.$1, attempt.$2),
            throwsA(isA<RemoteFailure>()
                .having((e) => e.code, 'code', 'invalid_credentials')));
      }
      final ok = await auth.signin('mei', friendPassword);
      expect((await auth.authenticate(ok.token))!.account.username, 'mei');
      expect(await store.revoke('mei'), isTrue);
      expect(await auth.authenticate(ok.token), isNull);
      await expectLater(
          auth.signin('mei', friendPassword), throwsA(isA<RemoteFailure>()));
    });
  });

  group('gateway', () {
    const ownerPassword = 'owner-password-123';
    late RemoteGateway gateway;
    late GuestStore store;
    late EngineController controller;
    late HttpClient client;
    late Map<String, String> cookies;

    Future<RemoteGateway> start({required bool guestsEnabled}) async {
      final salt = List<int>.generate(16, (i) => i);
      final key = await Pbkdf2.hmacSha256(iterations: 10, bits: 256)
          .deriveKeyFromPassword(password: ownerPassword, nonce: salt);
      controller = EngineController(engine: MockEngine());
      store = lowCostStore(dir);
      final g = RemoteGateway(
        auth: RemoteAuth(RemoteAccount(
            username: 'test-owner',
            salt: base64UrlEncode(salt),
            hash: base64UrlEncode(await key.extractBytes()),
            iterations: 10)),
        coordinator: AppSessionCoordinator(
            controller: controller,
            spatial: SpatialRuntimeAdapter()..bootstrap(controller.params),
            nativeBackend: true,
            liveRunning: () => false),
        guests: guestsEnabled ? GuestService(store) : null,
        loadAsset: (_) async => Uint8List.fromList(utf8.encode(
            '<meta content="LOGIN_CSRF_TOKEN"><meta content="GUEST_CSRF_TOKEN">'
            '<meta content="GUEST_MODE">')),
      );
      await g.start();
      client = HttpClient();
      cookies = {};
      return g;
    }

    tearDown(() async {
      client.close(force: true);
      await gateway.close();
      controller.dispose();
    });

    Future<({int status, Map<String, dynamic> json, String text})> request(
        String path,
        {Map<String, dynamic>? body,
        String? csrf,
        String? origin}) async {
      final req = await client.openUrl(
          body == null ? 'GET' : 'POST', gateway.origin.resolve(path));
      req.followRedirects = false;
      req.headers.set('Cookie',
          cookies.entries.map((e) => '${e.key}=${e.value}').join('; '));
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.headers.set('Origin', origin ?? gateway.origin.toString());
        if (csrf != null) req.headers.set('X-CSRF-Token', csrf);
        req.write(jsonEncode(body));
      }
      final response = await req.close();
      for (final cookie in response.cookies) {
        if (cookie.maxAge == 0) {
          cookies.remove(cookie.name);
        } else {
          cookies[cookie.name] = cookie.value;
        }
      }
      final text = await utf8.decodeStream(response);
      Map<String, dynamic> json = const {};
      try {
        final value = jsonDecode(text);
        if (value is Map<String, dynamic>) json = value;
      } catch (_) {}
      return (status: response.statusCode, json: json, text: text);
    }

    Future<void> acceptInvite(String token) async {
      await request('/remote/guest/invite');
      final nonce = cookies['yinwei_guest_pre']!;
      final r = await request('/remote/guest/api/invite',
          body: {
            'token': token,
            'username': 'mei',
            'displayName': 'Mei',
            'password': friendPassword
          },
          csrf: nonce);
      expect(r.status, 200, reason: r.text);
    }

    test('guest routes do not exist unless enabled', () async {
      gateway = await start(guestsEnabled: false);
      for (final path in [
        '/remote/guest/signin',
        '/remote/guest/invite',
        '/remote/guest/api/session'
      ]) {
        expect((await request(path)).status, 404, reason: path);
      }
    });

    test('invite → account → guest session; invite is single use', () async {
      gateway = await start(guestsEnabled: true);
      final token = await store.createInvite();
      await acceptInvite(token);
      final session = await request('/remote/guest/api/session');
      expect(session.status, 200);
      expect(session.json['displayName'], 'Mei');
      expect(session.json['role'], 'guest');

      cookies.clear();
      await request('/remote/guest/invite');
      final again = await request('/remote/guest/api/invite',
          body: {
            'token': token,
            'username': 'mei2',
            'displayName': 'Mei',
            'password': friendPassword
          },
          csrf: cookies['yinwei_guest_pre']);
      expect(again.status, 403);
      expect(again.json['error'], 'invalid_invite');
    });

    test('a guest session never opens owner routes', () async {
      gateway = await start(guestsEnabled: true);
      await acceptInvite(await store.createInvite());
      expect(cookies.keys, contains('yinwei_guest_local'));
      expect(cookies.keys, isNot(contains('yinwei_local')));
      for (final path in [
        '/remote/api/session',
        '/remote/api/media',
        '/remote/app'
      ]) {
        final r = await request(path);
        expect(r.status, anyOf(401, 303), reason: path);
      }
    });

    test('an owner session never opens guest routes', () async {
      gateway = await start(guestsEnabled: true);
      await request('/remote/signin');
      final ownerSignin = await request('/remote/api/auth/signin',
          body: {'username': 'test-owner', 'password': ownerPassword},
          csrf: cookies['yinwei_prelogin']);
      expect(ownerSignin.status, 200);
      expect((await request('/remote/api/session')).status, 200);
      expect((await request('/remote/guest/api/session')).status, 401);
    });

    test('guest posts need CSRF and same origin; revoke ends the session',
        () async {
      gateway = await start(guestsEnabled: true);
      await acceptInvite(await store.createInvite());
      final csrf =
          (await request('/remote/guest/api/session')).json['csrf'] as String;
      expect(
          (await request('/remote/guest/api/signout', body: {})).status, 403);
      expect(
          (await request('/remote/guest/api/signout',
                  body: {}, csrf: csrf, origin: 'https://evil.example'))
              .status,
          403);
      await store.revoke('mei');
      expect((await request('/remote/guest/api/session')).status, 401);
    });

    test('guest sign-in with the account password', () async {
      gateway = await start(guestsEnabled: true);
      await acceptInvite(await store.createInvite());
      cookies.clear();
      await request('/remote/guest/signin');
      final bad = await request('/remote/guest/api/signin',
          body: {'username': 'mei', 'password': 'wrong-password-000'},
          csrf: cookies['yinwei_guest_pre']);
      expect(bad.status, 401);
      await request('/remote/guest/signin');
      final good = await request('/remote/guest/api/signin',
          body: {'username': 'mei', 'password': friendPassword},
          csrf: cookies['yinwei_guest_pre']);
      expect(good.status, 200);
      expect((await request('/remote/guest/api/session')).status, 200);
    });
  });
}
