import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/platform/ios_remote_live_session.dart';

const _entry =
    'https://yinwei-remote-entry-01a12de8.yinwei-01a12de8.workers.dev/';
const _laptop = 'https://fixture-laptop.trycloudflare.com';

// Route production HTTP requests to a real local fixture without weakening
// origin validation or adding a test-only origin bypass to the app.
class _FixtureHttp extends HttpOverrides {
  _FixtureHttp(this.port, this.requests);
  final int port;
  final List<Uri> requests;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FixtureClient(super.createHttpClient(context), port, requests);
}

class _FixtureClient implements HttpClient {
  _FixtureClient(this.inner, this.port, this.requests);
  final HttpClient inner;
  final int port;
  final List<Uri> requests;

  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;
  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    requests.add(url);
    return inner.openUrl(
        method, url.replace(scheme: 'http', host: '127.0.0.1', port: port));
  }

  @override
  void close({bool force = false}) => inner.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('signin-fixture');
  late HttpServer server;
  late List<Uri> requests;
  late String? redirect;
  late int entryStatus, loginStatus, sessionStatus;
  late List<String> loginBodies;

  setUp(() async {
    requests = [];
    loginBodies = [];
    redirect = '$_laptop/remote/signin';
    entryStatus = 303;
    loginStatus = sessionStatus = 200;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/':
          // This was the original bug: the root never redirects.
          response.write('<html>Open Yinwei</html>');
        case '/open':
          response.statusCode = entryStatus;
          if (redirect != null) response.headers.set('location', redirect!);
        case '/remote/signin':
          response.cookies
              .add(Cookie('__Host-yinwei_prelogin', 'fixture-nonce'));
          response.write('<html>Sign in</html>');
        case '/remote/api/auth/signin':
          loginBodies.add(await utf8.decoder.bind(request).join());
          expect(request.headers.value('x-csrf-token'), 'fixture-nonce');
          response.statusCode = loginStatus;
          response.cookies.add(Cookie('__Host-yinwei', 'fixture-session'));
          response.write('{}');
        case '/remote/api/session':
          response.statusCode = sessionStatus;
          response.write('{"csrf":"fixture-csrf"}');
        default:
          response.statusCode = 404;
      }
      await response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> signIn(void Function(IosRemoteLiveSession) check,
      {String entry = _entry}) async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final session = IosRemoteLiveSession(channel: channel);
      try {
        await session.signIn(entry, 'fixture-owner', 'fixture-password');
        expect(session.busy, false);
        check(session);
      } finally {
        session.dispose();
        await Future<void>.delayed(Duration.zero);
      }
    }, _FixtureHttp(server.port, requests));
  }

  test('fixed bookmark resolves /open before signing into trusted laptop',
      () async {
    await signIn((session) => expect(session.signedIn, true));
    expect(requests.map((uri) => uri.path), [
      '/open',
      '/remote/signin',
      '/remote/api/auth/signin',
      '/remote/api/session'
    ]);
    expect(requests.first.host, Uri.parse(_entry).host);
    expect(requests.skip(1).every((uri) => uri.origin == _laptop), true);
    expect(jsonDecode(loginBodies.single),
        {'username': 'fixture-owner', 'password': 'fixture-password'});
  });

  test('offline landing page gives backend instructions without sending login',
      () async {
    entryStatus = 200;
    redirect = null;
    await signIn((session) {
      expect(session.signedIn, false);
      expect(session.status, contains('BACKEND READY'));
    });
    expect(requests.length, 1);
    expect(loginBodies, isEmpty);
  });

  for (final destination in [
    'https://attacker.example/remote/signin',
    'http://fixture-laptop.trycloudflare.com/remote/signin',
    'https://user@fixture-laptop.trycloudflare.com/remote/signin',
    '$_laptop/remote/signin?token=secret',
    '$_laptop/remote/signin#fragment',
    '$_laptop/other',
  ]) {
    test('untrusted redirect is rejected: $destination', () async {
      redirect = destination;
      await signIn((session) {
        expect(session.signedIn, false);
        expect(session.status, contains('trusted laptop connection'));
      });
      expect(requests.length, 1);
      expect(loginBodies, isEmpty);
    });
  }

  for (final failure in {
    401: 'Owner account or password was rejected',
    403: 'Sign-in session expired or was rejected',
    429: 'Too many sign-in attempts',
    502: 'Laptop connection failed (HTTP 502)',
  }.entries) {
    test('sign-in HTTP ${failure.key} has a distinct message', () async {
      loginStatus = failure.key;
      await signIn((session) {
        expect(session.signedIn, false);
        expect(session.status, contains(failure.value));
        expect(session.status, isNot(contains('fixture-password')));
      });
    });
  }

  test('session rejection after login is not reported as a wrong password',
      () async {
    sessionStatus = 401;
    await signIn((session) {
      expect(session.signedIn, false);
      expect(session.status, contains('session expired or was rejected'));
    });
  });

  test('unsupported bookmark is rejected before any request', () async {
    await signIn((session) {
      expect(session.signedIn, false);
      expect(session.status, 'Use the Yinwei entry link');
    }, entry: 'https://attacker.example');
    expect(requests, isEmpty);
  });
}
