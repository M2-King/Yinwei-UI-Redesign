import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yinwei_player/remote/remote_protocol.dart';
import 'package:yinwei_player/remote/soda_online.dart';

class _Headers implements HttpHeaders {
  final values = <String, String>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name] = '$value';
  @override
  String? value(String name) => values[name];
  @override
  set contentType(ContentType? value) => values['content-type'] = '$value';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.bytes, {this.statusCode = 200, int? length, this.encoding})
      : contentLength = length ?? bytes.length;
  final List<int> bytes;
  final String? encoding;
  @override
  final int statusCode, contentLength;
  @override
  HttpHeaders get headers => _Headers()
    ..values.addAll({if (encoding != null) 'content-encoding': encoding!});
  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      Stream.value(bytes).listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.reply);
  final Future<HttpClientResponse> Function() reply;
  @override
  final _Headers headers = _Headers();
  @override
  bool followRedirects = true;
  String body = '';
  @override
  void write(Object? value) {
    body += '$value';
  }

  @override
  Future<HttpClientResponse> close() => reply();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements HttpClient {
  _Client(this.request);
  final _Request request;
  Uri? uri;
  String? method;
  bool closed = false;
  @override
  bool autoUncompress = true;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    this.method = method;
    uri = url;
    return request;
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory temp;
  late SodaOnline service;
  late _Client client;
  late DateTime now;
  late Object body;
  late Future<HttpClientResponse> Function() reply;
  Map<String, dynamic> track([String id = '7399000000000000001']) => {
        'id': id,
        'name': 'Fixture 晴天',
        'artists': [
          {'name': 'Fixture artist'}
        ],
        'duration': 231000,
        'media_type': 'track',
        'vid': 'fixture-video',
        'status': 0,
        'audio_url': 'https://not-returned.invalid/audio',
        'sessionid': 'never-returned'
      };
  Map<String, dynamic> search(List<Object> tracks) => {
        'result_groups': [
          {
            'data': [
              for (final t in tracks)
                {
                  'entity': {'track': t}
                }
            ]
          }
        ]
      };
  Matcher failure(String code) =>
      isA<RemoteFailure>().having((e) => e.code, 'code', code);
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('yinwei-online-fixture-');
    now = DateTime.utc(2026, 10, 22);
    body = search([track()]);
    reply = () async => _Response(utf8.encode(jsonEncode(body)));
    service = SodaOnline(
        identityDirectory: temp,
        clock: () => now,
        playbackVerified: true,
        clientFactory: () {
          client = _Client(_Request(() => reply()));
          return client;
        });
  });
  tearDown(() async {
    service.close();
    await temp.delete(recursive: true);
  });

  test('fixed anonymous request, own persisted IDs, opaque results, no secrets',
      () async {
    final value = await service.browse('search', {'query': '晴天'});
    expect(client.uri!.host, 'api.qishui.com');
    expect(client.uri!.path, '/luna/search/track');
    expect(client.uri!.queryParameters['q'], '晴天');
    expect(client.method, 'GET');
    expect(client.request.followRedirects, false);
    expect(client.autoUncompress, false);
    expect(client.request.headers.values.keys, isNot(contains('Cookie')));
    final encoded = jsonEncode(value);
    expect(encoded, isNot(contains('7399000000000000001')));
    expect(encoded, isNot(contains('never-returned')));
    expect(encoded, isNot(contains('audio_url')));
    expect((value['rows'] as List).single['title'], 'Fixture 晴天');
    final saved = jsonDecode(
        await File('${temp.path}${Platform.pathSeparator}device.json')
            .readAsString());
    expect(saved['device_id'], client.uri!.queryParameters['device_id']);
    expect(client.closed, true);
  });
  test('handles resolve only at current revision and expire', () async {
    final v = await service.browse('search', {'query': 'rain'});
    final row = (v['rows'] as List).single;
    final selection = {'revision': v['revision'], 'track': row['id']};
    expect(service.resolveTrack(selection), '7399000000000000001');
    expect(() => service.resolveTrack({...selection, 'revision': 'old'}),
        throwsA(failure('soda_stale_selection')));
    expect(
        () => service
            .resolveTrack({...selection, 'track': '7399000000000000001'}),
        throwsA(failure('soda_stale_selection')));
    expect(() => service.resolveTrack({...selection, 'url': 'luna://anything'}),
        throwsA(failure('soda_invalid_selection')));
    now = now.add(const Duration(seconds: 60));
    expect(() => service.resolveTrack(selection),
        throwsA(failure('soda_stale_selection')));
  });
  test('default adapter is browse only until playback proof passes', () async {
    service.close();
    service = SodaOnline(
        identityDirectory: temp,
        clientFactory: () {
          client = _Client(_Request(() => reply()));
          return client;
        });
    final v = await service.browse('search', {'query': 'rain'});
    expect(v['playbackReady'], false);
    expect((v['rows'] as List).single['playable'], false);
    expect(() => service.resolveTrack({'track': 'x', 'revision': 'y'}),
        throwsA(failure('soda_playback_unverified')));
  });
  test('known unavailable status and missing media metadata disable play',
      () async {
    body = search([
      {...track(), 'status': 2},
      {...track('7399000000000000002')}..remove('vid')
    ]);
    final v = await service.browse('search', {'query': 'rain'});
    expect((v['rows'] as List).every((r) => r['playable'] == false), true);
  });
  test(
      'invalid IDs, duplicate IDs and non-track media are excluded; rows bounded',
      () async {
    body = search([
      track(),
      track(),
      {...track(), 'id': 7399000000000000001},
      track('bad/path'),
      {...track('44'), 'media_type': 'video'},
      for (var i = 0; i < 40; i++) track('${1000 + i}')
    ]);
    final v = await service.browse('search', {'query': 'rain'});
    expect((v['rows'] as List).length, 20);
  });
  test('Unicode query bound and arbitrary fields rejected before networking',
      () async {
    for (final p in <Map<String, dynamic>>[
      {},
      {'query': 'a'},
      {'query': 'a\nb'},
      {'query': '😀' * 121},
      {'query': 'rain', 'url': 'https://elsewhere'}
    ]) {
      await expectLater(
          service.browse('search', p), throwsA(failure('invalid_payload')));
    }
    await service.browse('search', {'query': '😀😀'});
    expect(client.uri!.queryParameters['q'], '😀😀');
  });
  test('empty valid search differs from empty body and schema failure',
      () async {
    body = search([]);
    expect(
        (await service.browse('search', {'query': 'empty'}))['rows'], isEmpty);
    body = {'status_code': 1000006};
    await expectLater(service.browse('search', {'query': 'blocked'}),
        throwsA(failure('soda_online_rejected')));
    reply = () async => _Response([]);
    await expectLater(service.browse('search', {'query': 'blank'}),
        throwsA(failure('soda_schema_changed')));
  });
  test(
      'redirect and compressed response rejected without following or decoding',
      () async {
    reply = () async => _Response([], statusCode: 302);
    await expectLater(service.browse('search', {'query': 'redirect'}),
        throwsA(failure('soda_online_unavailable')));
    reply = () async => _Response([], encoding: 'gzip');
    await expectLater(service.browse('search', {'query': 'compressed'}),
        throwsA(failure('soda_online_unavailable')));
  });
  test('actual bytes and JSON nesting are bounded', () async {
    reply =
        () async => _Response(List.filled(2 * 1024 * 1024 + 1, 32), length: -1);
    await expectLater(service.browse('search', {'query': 'large'}),
        throwsA(failure('soda_response_too_large')));
    reply = () async => _Response(utf8.encode('${'[' * 33}0${']' * 33}'));
    await expectLater(service.browse('search', {'query': 'deep'}),
        throwsA(failure('soda_schema_changed')));
  });
  test('identical cached query keeps handles; only five pages retained',
      () async {
    final v = await service.browse('search', {'query': 'same'});
    expect((await service.browse('search', {'query': 'same'}))['revision'],
        v['revision']);
    for (var i = 0; i < 5; i++) {
      await service.browse('search', {'query': 'other$i'});
    }
    expect(
        () => service.resolveTrack({
              'revision': v['revision'],
              'track': (v['rows'] as List).single['id']
            }),
        throwsA(failure('soda_stale_selection')));
  });
  test('late superseded search cannot publish handles', () async {
    final gate = Completer<HttpClientResponse>();
    reply = () => gate.future;
    final first = service.browse('search', {'query': 'first'});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final previous = client;
    reply = () async => _Response(utf8.encode(jsonEncode(body)));
    final second = service.browse('search', {'query': 'second'});
    final expectation = expectLater(first, throwsA(failure('soda_superseded')));
    await Future<void>.delayed(Duration.zero);
    expect(previous.closed, false,
        reason: 'typing must not repeatedly abort the provider connection');
    gate.complete(_Response(utf8.encode(jsonEncode(body))));
    await expectation;
    await second;
    expect(previous.closed, true);
  });
  test('rapid replacement searches run only the active and newest request',
      () async {
    final gate = Completer<HttpClientResponse>();
    var requests = 0;
    reply = () {
      requests++;
      return requests == 1
          ? gate.future
          : Future.value(_Response(utf8.encode(jsonEncode(body))));
    };
    final first = service.browse('search', {'query': 'first'});
    final firstCheck = expectLater(first, throwsA(failure('soda_superseded')));
    while (requests == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    final running = client;
    final replaced = <Future<void>>[];
    for (var i = 0; i < 5; i++) {
      replaced.add(expectLater(service.browse('search', {'query': 'middle$i'}),
          throwsA(failure('soda_superseded'))));
    }
    final newest = service.browse('search', {'query': 'newest'});
    expect(requests, 1);
    expect(running.closed, false);
    gate.complete(_Response(utf8.encode(jsonEncode(body))));
    await firstCheck;
    await Future.wait(replaced);
    expect((await newest)['query'], 'newest');
    expect(requests, 2);
    for (var i = 0; i < 8; i++) {
      expect((await service.browse('search', {'query': 'next$i'}))['rows'],
          hasLength(1));
    }
  });
  test('provider throttling backs off without retries and then recovers',
      () async {
    var requests = 0;
    reply = () async {
      requests++;
      return _Response([], statusCode: 429);
    };
    await expectLater(service.browse('search', {'query': 'first'}),
        throwsA(failure('soda_online_rate_limited')));
    await expectLater(service.browse('search', {'query': 'second'}),
        throwsA(failure('soda_online_rate_limited')));
    expect(requests, 1);
    now = now.add(const Duration(seconds: 31));
    reply = () async {
      requests++;
      return _Response(utf8.encode(jsonEncode(body)));
    };
    expect((await service.browse('search', {'query': 'recovered'}))['rows'],
        hasLength(1));
    expect(requests, 2);
  });
  test('an active failure releases the latest waiting search', () async {
    final gate = Completer<HttpClientResponse>();
    reply = () => gate.future;
    final first = service.browse('search', {'query': 'first'});
    final check =
        expectLater(first, throwsA(failure('soda_online_unavailable')));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    reply = () async => _Response(utf8.encode(jsonEncode(body)));
    final newest = service.browse('search', {'query': 'newest'});
    gate.completeError(const SocketException('fixture'));
    await check;
    expect((await newest)['query'], 'newest');
  });
  test('deadline closes active socket and does not return stale data',
      () async {
    service.close();
    service = SodaOnline(
        identityDirectory: temp,
        timeout: const Duration(milliseconds: 30),
        clientFactory: () {
          client =
              _Client(_Request(() => Completer<HttpClientResponse>().future));
          return client;
        });
    await expectLater(service.browse('search', {'query': 'timeout'}),
        throwsA(failure('soda_online_timeout')));
    expect(client.closed, true);
  });
  test('catalogue uses fixed POST and exposes opaque, disabled mode entries',
      () async {
    body = {
      'status_code': 0,
      'feed_mode_block': [
        {
          'items': [
            {
              'text': 'Focus fixture',
              'entity': {
                'feed_scene_mode': {
                  'scene_mode_id': 6,
                  'sub_queue_type': 'scene_mode_focus'
                }
              }
            }
          ]
        }
      ]
    };
    final v = await service.browse('modes', {});
    expect(client.method, 'POST');
    expect(client.request.body, '{}');
    expect((v['modes'] as List).single['label'], 'Focus fixture');
    expect((v['modes'] as List).single['browseable'], false);
    expect(jsonEncode(v), isNot(contains('scene_mode_focus')));
  });
  test('corrupt persisted identity fails closed without replacing it',
      () async {
    final file = File('${temp.path}${Platform.pathSeparator}device.json');
    await file.writeAsString('bad');
    await expectLater(service.browse('search', {'query': 'rain'}),
        throwsA(failure('soda_schema_changed')));
    expect(await file.readAsString(), 'bad');
  });
  test('close invalidates all current handles and future requests', () async {
    final v = await service.browse('search', {'query': 'rain'});
    service.close();
    expect(
        () => service.resolveTrack({
              'revision': v['revision'],
              'track': (v['rows'] as List).single['id']
            }),
        throwsA(failure('soda_invalid_selection')));
    await expectLater(service.browse('search', {'query': 'rain'}),
        throwsA(failure('host_closed')));
  });
}
