import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'remote_protocol.dart';

/// Anonymous metadata only. Protocol references and licences:
/// docs/SODA_ONLINE_INTEGRATION_PROGRESS.md. Never reads desktop credentials,
/// follows redirects, resolves audio URLs, or accepts a client-supplied URL/ID.
class SodaOnline {
  SodaOnline({
    required this.identityDirectory,
    HttpClient Function()? clientFactory,
    DateTime Function()? clock,
    this.playbackVerified = false,
    this.timeout = const Duration(seconds: 10),
  })  : _clientFactory = clientFactory ?? HttpClient.new,
        _clock = clock ?? DateTime.now;

  final Directory identityDirectory;
  final HttpClient Function() _clientFactory;
  final DateTime Function() _clock;
  final bool playbackVerified;
  final Duration timeout;
  final _random = Random.secure();
  final _cache = <String, _OnlinePage>{};
  /// How long a shown search result can still be played (it was 60 s, which
  /// made a quick-menu tap on a search result fail a minute later).
  static const playableFor = Duration(minutes: 15);
  Future<Map<String, String>>? _identity;
  HttpClient? _active;
  Future<void>? _inFlight;
  DateTime? _retryAfter;
  int _generation = 0;
  bool _closed = false;

  String _token() =>
      base64UrlEncode(List<int>.generate(24, (_) => _random.nextInt(256)))
          .replaceAll('=', '');

  Future<Map<String, String>> _loadIdentity() async {
    final file =
        File('${identityDirectory.path}${Platform.pathSeparator}device.json');
    if (await file.exists()) {
      if (await file.length() > 1024) {
        throw const RemoteFailure('soda_identity_invalid');
      }
      final value = jsonDecode(await file.readAsString());
      if (value is! Map ||
          value.length != 3 ||
          !RegExp(r'^[0-9]{16}$').hasMatch('${value['device_id']}') ||
          !RegExp(r'^[0-9]{16}$').hasMatch('${value['iid']}') ||
          !RegExp(r'^[A-Za-z0-9_-]{32}$').hasMatch('${value['cdid']}')) {
        throw const RemoteFailure('soda_identity_invalid');
      }
      return {
        for (final key in ['device_id', 'iid', 'cdid'])
          key: value[key] as String
      };
    }
    // Locally generated identifiers, never borrowed from reference projects.
    String number() =>
        '1${List.generate(15, (_) => _random.nextInt(10)).join()}';
    final result = {'device_id': number(), 'iid': number(), 'cdid': _token()};
    await identityDirectory.create(recursive: true);
    await file.writeAsString(jsonEncode(result), flush: true);
    return result;
  }

  Future<Map<String, dynamic>> browse(
      String kind, Map<String, dynamic> payload) async {
    if (_closed) throw const RemoteFailure('host_closed');
    if (!const ['search', 'modes'].contains(kind) ||
        payload.keys.any((key) => key != 'query') ||
        (kind == 'modes' && payload.isNotEmpty)) {
      throw const RemoteFailure('invalid_payload', httpStatus: 400);
    }
    final query = payload['query'];
    final q = query is String ? query.trim() : '';
    if (kind == 'search' &&
        (query is! String ||
            q.runes.length < 2 ||
            q.runes.length > 120 ||
            q.runes.any((c) => c < 32))) {
      throw const RemoteFailure('invalid_payload', httpStatus: 400);
    }
    final generation = ++_generation;
    // Finish the current bounded provider read instead of repeatedly aborting
    // sockets while someone types. Only the newest waiting intent may start.
    while (_inFlight != null) {
      await _inFlight;
      if (_closed || generation != _generation) {
        throw const RemoteFailure('soda_superseded');
      }
    }
    final finished = Completer<void>();
    _inFlight = finished.future;
    try {
      return await _browse(kind, q, generation);
    } finally {
      _inFlight = null;
      finished.complete();
    }
  }

  Future<Map<String, dynamic>> _browse(
      String kind, String q, int generation) async {
    final key = '$kind:$q';
    final cached = _cache.remove(key);
    if (cached != null &&
        _clock().difference(cached.created) < const Duration(seconds: 60)) {
      _cache[key] = cached;
      return {...cached.public, 'cached': true};
    }
    if (_retryAfter?.isAfter(_clock()) == true) {
      throw const RemoteFailure('soda_online_rate_limited');
    }
    final client = _clientFactory();
    client.autoUncompress = false;
    _active = client;
    final timer = Stopwatch()..start();
    try {
      final body = await (() async {
        final identity = await (_identity ??= _loadIdentity());
        if (_closed || generation != _generation) {
          throw const RemoteFailure('soda_superseded');
        }
        final params = <String, String>{
          ...identity,
          'aid': '386088',
          'channel': 'official',
          'ac': 'wifi',
          'tz_name': 'Asia/Shanghai',
          'sim_region': 'cn',
          if (kind == 'search') ...{
            'app_name': 'luna',
            'device_platform': 'android',
            'os': 'android',
            'version_name': '19.8.0',
            'version_code': '100198030',
            'language': 'zh',
            'need_personal_recommend': '0',
            'q': q,
            'cursor': '0',
            'count': '20',
            '_rticket': '${_clock().millisecondsSinceEpoch}',
          } else ...{
            'app_name': 'luna_pc',
            'device_platform': 'windows',
            'version_name': '3.0.0',
            'version_code': '30000000',
            'region': 'cn',
            'geo_region': 'cn',
            'os_region': 'cn',
            'os_version': 'Windows 11',
            'device_type': 'Windows',
            'fp': identity['device_id']!,
          }
        };
        final uri = Uri.https(
            'api.qishui.com',
            kind == 'search' ? '/luna/search/track' : '/luna/pc/feed/mode',
            params);
        final request =
            await client.openUrl(kind == 'search' ? 'GET' : 'POST', uri);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        request.headers.set(
            HttpHeaders.userAgentHeader,
            kind == 'search'
                ? 'com.luna.music/100198030 (Linux; Android 15; tt-ok/3.12.13.19)'
                : 'LunaPC/3.0.0(290101097)');
        if (kind == 'modes') {
          request.headers.contentType = ContentType.json;
          request.write('{}');
        }
        final response = await request.close();
        if (response.statusCode == 429) {
          final seconds = int.tryParse(
                  response.headers.value(HttpHeaders.retryAfterHeader) ?? '') ??
              30;
          _retryAfter = _clock().add(Duration(seconds: seconds.clamp(1, 120)));
          throw const RemoteFailure('soda_online_rate_limited');
        }
        if (response.statusCode != 200 ||
            response.headers.value(HttpHeaders.contentEncodingHeader) != null ||
            response.contentLength > 2 * 1024 * 1024) {
          throw const RemoteFailure('soda_online_unavailable');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 2 * 1024 * 1024) {
            throw const RemoteFailure('soda_response_too_large');
          }
          bytes.addAll(chunk);
        }
        final text = utf8.decode(bytes);
        _checkDepth(text);
        final decoded = jsonDecode(text);
        if (decoded is! Map<String, dynamic>) throw const FormatException();
        return decoded;
      })()
          .timeout(timeout);
      if (_closed || generation != _generation) {
        throw const RemoteFailure('soda_superseded');
      }
      final tracks = <String, String>{};
      final rows = <Map<String, dynamic>>[];
      final modes = <Map<String, dynamic>>[];
      if (body['status_code'] != null && body['status_code'] != 0) {
        throw const RemoteFailure('soda_online_rejected');
      }
      if (kind == 'search') {
        final groups = body['result_groups'];
        if (groups is! List) {
          throw const RemoteFailure('soda_schema_changed');
        }
        final seen = <String>{};
        for (final group in groups.whereType<Map>()) {
          if (group['data'] is! List) continue;
          for (final entry in (group['data'] as List).whereType<Map>()) {
            final entity = entry['entity'];
            final t = entity is Map ? entity['track'] : null;
            if (t is! Map) continue;
            final id = t['id'];
            final duration = t['duration'];
            if (id is! String ||
                !RegExp(r'^[0-9]{1,32}$').hasMatch(id) ||
                !seen.add(id) ||
                t['name'] is! String ||
                (t['name'] as String).trim().isEmpty ||
                (t['media_type'] != null && t['media_type'] != 'track') ||
                duration is! int ||
                duration <= 0 ||
                duration > 86400000 ||
                rows.length >= 20) {
              continue;
            }
            final handle = _token();
            tracks[handle] = id;
            final artists = t['artists'];
            rows.add({
              'id': handle,
              'title': _text(t['name'], 240),
              'artist': artists is List
                  ? artists
                      .whereType<Map>()
                      .take(8)
                      .map((a) => _text(a['name'], 120))
                      .where((a) => a.isNotEmpty)
                      .join(' / ')
                  : '',
              'durationMs': duration,
              'playable': playbackVerified &&
                  (t['status'] == null || t['status'] == 0) &&
                  t['vid'] is String &&
                  (t['vid'] as String).isNotEmpty
            });
          }
        }
      } else {
        if (body['status_code'] != 0 || body['feed_mode_block'] is! List) {
          throw const RemoteFailure('soda_schema_changed');
        }
        void walk(Object? value) {
          if (modes.length >= 80) return;
          if (value is List) {
            for (final v in value) {
              walk(v);
            }
          }
          if (value is Map) {
            final entity = value['entity'];
            final scene = entity is Map ? entity['feed_scene_mode'] : null;
            if (scene is Map &&
                value['text'] is String &&
                RegExp(r'^[0-9]{1,12}$')
                    .hasMatch('${scene['scene_mode_id']}')) {
              modes.add({
                'id': _token(),
                'label': _text(value['text'], 120),
                'browseable': false
              });
            }
            for (final v in value.values) {
              walk(v);
            }
          }
        }

        walk(body['feed_mode_block']);
      }
      final revision = _token();
      final result = <String, dynamic>{
        'kind': kind,
        'revision': revision,
        'query': q,
        'rows': rows,
        'modes': modes,
        'elapsedMs': timer.elapsedMilliseconds,
        'cached': false,
        'playbackReady': playbackVerified,
        'source': 'anonymous-provider',
        'modeContentsAvailable': false
      };
      _cache[key] = _OnlinePage(_clock(), result, tracks);
      while (_cache.length > 5) {
        _cache.remove(_cache.keys.first);
      }
      return result;
    } on RemoteFailure {
      rethrow;
    } on TimeoutException {
      throw const RemoteFailure('soda_online_timeout');
    } on FormatException {
      throw const RemoteFailure('soda_schema_changed');
    } catch (_) {
      throw const RemoteFailure('soda_online_unavailable');
    } finally {
      client.close(force: true);
      if (identical(_active, client)) _active = null;
    }
  }

  String resolveTrack(Map<String, dynamic> payload) {
    if (!playbackVerified) {
      throw const RemoteFailure('soda_playback_unverified');
    }
    if (_closed ||
        payload.length != 2 ||
        payload['revision'] is! String ||
        payload['track'] is! String) {
      throw const RemoteFailure('soda_invalid_selection');
    }
    for (final page in _cache.values) {
      if (page.public['revision'] != payload['revision']) continue;
      // A shown result stays playable for playableFor (the iPad quick menu keeps
      // the list you played from); an older page is skipped, not the end of the
      // search (it used to stop at the first expired page).
      if (_clock().difference(page.created) >= playableFor) continue;
      final id = page.tracks[payload['track']];
      final rows = page.public['rows'] as List;
      if (id != null &&
          rows.any(
              (r) => r['id'] == payload['track'] && r['playable'] == true)) {
        return id;
      }
    }
    throw const RemoteFailure('soda_stale_selection');
  }

  static String _text(Object? value, int limit) =>
      value is String ? String.fromCharCodes(value.runes.take(limit)) : '';

  static void _checkDepth(String text) {
    var depth = 0, quoted = false, escaped = false;
    for (final c in text.codeUnits) {
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (c == 92) {
          escaped = true;
        } else if (c == 34) {
          quoted = false;
        }
      } else if (c == 34) {
        quoted = true;
      } else if (c == 91 || c == 123) {
        if (++depth > 32) throw const RemoteFailure('soda_schema_changed');
      } else if (c == 93 || c == 125) {
        --depth;
      }
    }
  }

  void close() {
    _closed = true;
    ++_generation;
    _active?.close(force: true);
    _cache.clear();
  }
}

class _OnlinePage {
  _OnlinePage(this.created, this.public, this.tracks);
  final DateTime created;
  final Map<String, dynamic> public;
  final Map<String, String> tracks;
}
