import 'listen_tap_trace.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'soda_cache_reader.dart';

class SodaLibraryFailure implements Exception {
  const SodaLibraryFailure(this.code);
  final String code;
  @override
  String toString() => 'SodaLibraryFailure($code)';
}

/// A bounded provider metadata adapter. It never invokes Soda, focuses a window,
/// reads credentials, downloads artwork/audio, or changes playback/capture.
class SodaLibrary {
  SodaLibrary({
    SodaCacheReader? reader,
    Directory? storageDirectory,
    void Function(Map<String, Object?> event)? log,
    DateTime Function()? clock,
    this.historyByteLimit = 64 * 1024 * 1024,
  })  : reader = reader ?? SodaCacheReader(),
        storageDirectory = storageDirectory ?? _defaultStorage(),
        _storageConfigured = storageDirectory != null ||
            (Platform.environment['LOCALAPPDATA'] ??
                    Platform.environment['APPDATA'] ??
                    '')
                .isNotEmpty,
        _log = log,
        _clock = clock ?? DateTime.now;
  final SodaCacheReader reader;
  final Directory storageDirectory;
  final bool _storageConfigured;
  final void Function(Map<String, Object?> event)? _log;
  final DateTime Function() _clock;
  final int historyByteLimit;
  int? _retainedBytes;
  final _random = Random.secure();
  final _lists = <String, _ListState>{};
  String? _account, _readerRevision;
  String _revision = '';
  Future<void>? _pending;
  DateTime? _lastRead;
  int _storedThisSession = 0;
  int _writeOrder = 0;
  bool get available => reader.available && _storageConfigured;
  static Directory _defaultStorage() => Directory(
      '${Platform.environment['LOCALAPPDATA'] ?? Platform.environment['APPDATA'] ?? ''}'
      '${Platform.pathSeparator}Yinwei${Platform.pathSeparator}remote'
      '${Platform.pathSeparator}soda-library-v1');
  String _token() =>
      base64UrlEncode(List<int>.generate(24, (_) => _random.nextInt(256)))
          .replaceAll('=', '');

  /// One read in flight; explicit refresh bypasses the browse debounce. A partial
  /// list is never a reason to retry or request more content from the provider.
  Future<void> refresh() {
    final pending = _pending;
    if (pending != null) return pending;
    late final Future<void> job;
    job = _refresh().whenComplete(() {
      if (identical(_pending, job)) _pending = null;
    });
    _pending = job;
    return job;
  }

  void _invalidate() {
    _lists.clear();
    _account = null;
    _readerRevision = null;
    _lastRead = null;
    _revision = _token();
  }

  Future<void> _refresh() async {
    SodaCacheState state;
    try {
      state = await reader.read();
    } on SodaCacheFailure catch (e) {
      // Without a stable account marker, even a previously cached view must not
      // leak into a newly logged-in account. Private history stays on disk.
      _invalidate();
      throw SodaLibraryFailure(
          e.code == 'soda_no_account' ? 'soda_unavailable' : e.code);
    } catch (_) {
      _invalidate();
      throw const SodaLibraryFailure('soda_source_busy');
    }
    if (_account != state.accountId) {
      _invalidate();
      _account = state.accountId;
    }
    _lastRead = _clock();
    if (_readerRevision == state.revision) return;
    final catalogData = state.catalog['data'];
    if (catalogData is! Map || catalogData['playlists'] is! List) {
      throw const SodaLibraryFailure('soda_source_corrupt');
    }
    final catalog =
        (catalogData['playlists'] as List).whereType<Map>().toList();
    if (catalog.length > 200) {
      throw const SodaLibraryFailure('soda_source_unsupported');
    }
    final next = <String, _ListState>{};
    for (final source in catalog) {
      final id = source['id'];
      if (id is! String || !RegExp(r'^[0-9]{1,32}$').hasMatch(id)) continue;
      final title = _text(source['title'], 160);
      if (title == null) continue;
      final previous = _lists[id];
      final list = previous ?? _ListState(id, _token());
      list.current = true;
      list.title = title;
      list.liked = source['type'] == 1;
      final detail = state.details[id];
      final snapshot = detail == null
          ? _normalize(source, state.catalog['time'], const [])
          : _detail(id, detail);
      snapshot.sourceRevision = sha256
          .convert(utf8.encode(jsonEncode(detail ?? state.catalog)))
          .toString();
      snapshot.fingerprint = sha256
          .convert(utf8.encode(jsonEncode(snapshot.privateJson())))
          .toString();
      if (list.latest?.fingerprint != snapshot.fingerprint) {
        if (previous == null) await _restore(state.accountId, list);
        final old = list.latest;
        if (old?.fingerprint != snapshot.fingerprint) {
          if (list.snapshots.length >= 199 || _storedThisSession >= 1000) {
            throw const SodaLibraryFailure('soda_history_full');
          }
          snapshot.token = _token();
          for (final track in snapshot.tracks) {
            track.token = _token();
          }
          // Store the new immutable snapshot before changing the latest pointer.
          // Older files/views are never deleted to make room for a shrink.
          await _persist(state.accountId, list, snapshot);
          list.snapshots.insert(0, snapshot);
          if (old != null && snapshot.tracks.length < old.tracks.length) {
            try {
              _log?.call({
                'event': 'music_cache_shrank',
                'previousCount': old.tracks.length,
                'currentCount': snapshot.tracks.length,
                'reportedTotal': snapshot.reportedTotal,
              });
            } catch (_) {/* Diagnostics must not replace playback state. */}
          }
        }
      }
      next[id] = list;
    }
    // Catalog removal is not permission to erase the same-session historical
    // view. Its rows become nonplayable; another account never sees it.
    for (final old in _lists.entries) {
      if (!next.containsKey(old.key)) {
        old.value.current = false;
        next[old.key] = old.value;
      }
    }
    if (next.length > 200) {
      throw const SodaLibraryFailure('soda_history_full');
    }
    _lists
      ..clear()
      ..addAll(next);
    _readerRevision = state.revision;
    _revision = _token();
  }

  _Snapshot _detail(String id, Map<String, dynamic> envelope) {
    final data = envelope['data'];
    if (data is! Map ||
        data['playlist'] is! Map ||
        data['playlist']['id'] != id ||
        data['media_resources'] is! List) {
      throw const SodaLibraryFailure('soda_source_corrupt');
    }
    final snapshot = _normalize(data['playlist'] as Map, envelope['time'],
        data['media_resources'] as List);
    final more = data['has_more'] ?? data['hasMore'];
    snapshot.sourceHasMore = more is bool ? more : null;
    return snapshot;
  }

  _Snapshot _normalize(Map playlist, Object? time, List resources) {
    if (resources.length > 10000) {
      throw const SodaLibraryFailure('soda_source_unsupported');
    }
    final tracks = <String, _Track>{};
    for (final r in resources) {
      if (r is! Map || r['type'] != 'track' || r['entity'] is! Map) continue;
      final entity = r['entity'] as Map;
      final wrapper = entity['track_wrapper'];
      final t = entity['track'] ?? (wrapper is Map ? wrapper['track'] : null);
      if (t is! Map) continue;
      final id = t['id'], duration = t['duration'];
      final title = _text(t['name'], 300);
      if (id is! String ||
          !RegExp(r'^[0-9]{1,32}$').hasMatch(id) ||
          title == null ||
          duration is! int ||
          duration <= 0 ||
          duration > 86400000) {
        continue;
      }
      final media = t['media_type'];
      if (media != null && media != 'track') continue;
      final artists = t['artists'];
      final names = artists is List
          ? artists
              .whereType<Map>()
              .map((a) => _text(a['name'], 120))
              .whereType<String>()
              .take(8)
              .join(' / ')
          : '';
      final status = t['status'];
      final vid = t['vid'];
      // Positive duration is metadata completeness, not entitlement. Known
      // cached blockers/unknown enum values disable a row instead of claiming
      // it is currently playable. The app remains the final playback authority.
      // A sale/VIP label alone does not establish this account's entitlement.
      // Let Soda make that decision; only known cached blockers disable a row.
      final supported =
          (status == null || status == 0) && vid is String && vid.isNotEmpty;
      tracks.putIfAbsent(
          id, () => _Track(id, title, names, duration, supported));
    }
    final rc = playlist['resource_cnt'];
    final n = rc is Map ? rc['track_cnt'] : null;
    final total = n is int && n >= 0 && n <= 10000000 ? n : null;
    final timestamp = time is int && time > 0 && time < 8640000000000000
        ? DateTime.fromMillisecondsSinceEpoch(time, isUtc: true)
            .toIso8601String()
        : null;
    final snapshot = _Snapshot(tracks.values.toList(),
        total != null && tracks.length <= total ? total : null, timestamp);
    snapshot.reportedTotal = total;
    snapshot.rawResourceCount = resources.length;
    return snapshot;
  }

  /// At most this many search results per request (no paging in v1).
  static const searchLimit = 50;
  static const searchMaxLength = 120;

  Future<Map<String, dynamic>> browse(Map<String, dynamic> request) async {
    if (!available) throw const SodaLibraryFailure('soda_unavailable');
    final query = request['query'];
    if (query != null &&
        (query is! String ||
            query.trim().isEmpty ||
            query.length > searchMaxLength ||
            request['list'] != null ||
            request['snapshot'] != null)) {
      throw const SodaLibraryFailure('soda_invalid_selection');
    }
    final pending = _pending;
    if (pending != null) await pending;
    if (_account != null) {
      try {
        final active = await reader.readAccount();
        if (active != _account) {
          _invalidate();
        }
      } on SodaCacheFailure catch (e) {
        _invalidate();
        throw SodaLibraryFailure(
            e.code == 'soda_no_account' ? 'soda_unavailable' : e.code);
      } catch (_) {
        _invalidate();
        throw const SodaLibraryFailure('soda_source_busy');
      }
    }
    if (_lastRead == null ||
        _clock().difference(_lastRead!) >= const Duration(seconds: 2)) {
      await refresh();
    }
    final ordered = _lists.values.toList()
      ..sort((a, b) =>
          a.liked != b.liked ? (a.liked ? -1 : 1) : a.title.compareTo(b.title));
    final response = <String, dynamic>{
      'available': true,
      'revision': _revision,
      'lists': ordered.map(_summary).toList(),
      'list': null,
      'page': null,
    };
    if (query != null) {
      response['search'] = _search(query as String, ordered);
      return response;
    }
    final requested = request['list'];
    if (requested == null) return response;
    final list = _lists.values.where((l) => l.token == requested).firstOrNull;
    if (list == null) throw const SodaLibraryFailure('soda_invalid_selection');
    final requestedSnapshot = request['snapshot'];
    final snapshot = requestedSnapshot == null
        ? list.latest
        : list.snapshots.where((s) => s.token == requestedSnapshot).firstOrNull;
    if (snapshot == null) {
      throw const SodaLibraryFailure('soda_invalid_selection');
    }
    final offset = request['offset'] ?? 0;
    if (offset is! int || offset < 0 || offset > snapshot.tracks.length) {
      throw const SodaLibraryFailure('soda_invalid_selection');
    }
    final end = min(offset + 100, snapshot.tracks.length);
    final historical = !list.current || !identical(snapshot, list.latest);
    response['list'] = {
      ..._summary(list),
      'snapshots': list.snapshots
          .map((s) => {
                'id': s.token,
                'cached': s.tracks.length,
                'total': s.total,
                'updatedAt': s.updatedAt,
                'historical': !list.current || !identical(s, list.latest),
                'playable': list.current && identical(s, list.latest),
              })
          .toList()
    };
    response['page'] = {
      'snapshot': snapshot.token,
      'offset': offset,
      'nextOffset': end < snapshot.tracks.length ? end : null,
      'historical': historical,
      'rows': snapshot.tracks
          .sublist(offset, end)
          .map((t) => {
                'id': t.token,
                'title': t.title,
                'artist': t.artist,
                'durationMs': t.duration,
                'playable': !historical && t.supported,
                'historical': historical,
              })
          .toList(),
    };
    return response;
  }

  /// Search the cached songs: every word must appear in the title or artist,
  /// case-insensitively. Only the newest snapshot of lists still in 汽水's
  /// cache is searched, so every result is playable through [resolveTrack]
  /// with its own list and snapshot. A song in several lists appears once,
  /// under the first list in sheet order (Liked songs first).
  Map<String, dynamic> _search(String raw, List<_ListState> ordered) {
    final terms = _fold(raw).split(' ').where((t) => t.isNotEmpty).toList();
    final seen = <String>{};
    final rows = <Map<String, dynamic>>[];
    var more = false;
    outer:
    for (final list in ordered) {
      final s = list.latest;
      if (!list.current || s == null) continue;
      for (final t in s.tracks) {
        final text = _fold('${t.title} ${t.artist}');
        if (!terms.every(text.contains) || !seen.add(t.id)) continue;
        if (rows.length == searchLimit) {
          more = true;
          break outer;
        }
        rows.add({
          'id': t.token,
          'list': list.token,
          'snapshot': s.token,
          'listTitle': list.title,
          'title': t.title,
          'artist': t.artist,
          'durationMs': t.duration,
          'playable': t.supported,
        });
      }
    }
    return {'query': raw.trim(), 'rows': rows, 'more': more};
  }

  /// Lower case, one space between words, and the iPad keyboard's curly
  /// apostrophes/quotes treated as straight ones ("Don’t" finds "Don't").
  static String _fold(String value) => value
      .toLowerCase()
      .replaceAll(RegExp('[‘’‛′＇]'), "'")
      .replaceAll(RegExp('[“”‟″＂]'), '"')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Map<String, dynamic> _summary(_ListState list) {
    final s = list.latest;
    return {
      'id': list.token,
      'title': list.title,
      'liked': list.liked,
      'cached': s?.tracks.length ?? 0,
      'total': s?.total,
      'updatedAt': s?.updatedAt,
      'partial': s?.total != null && s!.tracks.length < s.total!,
      'historyCount': max(0, list.snapshots.length - 1),
      'historical': !list.current,
    };
  }

  /// A final launcher fence may reuse a snapshot younger than one second,
  /// but always re-reads the account. Slow handler checks do a full refresh.
  Future<String> resolveTrack(Map<String, dynamic> payload,
      {bool revalidate = false}) async {
    final revision = payload['revision'];
    if (payload.keys.any((key) =>
        !const ['list', 'snapshot', 'track', 'revision'].contains(key))) {
      throw const SodaLibraryFailure('soda_invalid_selection');
    }
    // Re-read the account and coherent source snapshot even inside the browse
    // debounce. No stale selection may launch content in another account: an
    // account change clears every list, so old list/snapshot/track tokens can
    // no longer resolve at all.
    final clock = Stopwatch()..start();
    ListenTapTrace.mark('host.resolve.start');
    final age = _lastRead == null ? null : _clock().difference(_lastRead!);
    final reuse = revalidate && _pending == null && age != null &&
        !age.isNegative && age < const Duration(seconds: 1);
    if (reuse) {
      String active;
      try {
        active = await reader.readAccount();
      } on SodaCacheFailure catch (e) {
        _invalidate();
        throw SodaLibraryFailure(e.code == 'soda_no_account' ? 'soda_unavailable' : e.code);
      } catch (_) {
        _invalidate();
        throw const SodaLibraryFailure('soda_source_busy');
      }
      if (active != _account) {
        _invalidate();
        throw const SodaLibraryFailure('soda_stale_selection');
      }
    } else {
      await refresh();
    }
    ListenTapTrace.mark('host.resolve.refresh', {'us': clock.elapsedMicroseconds, 'accountOnly': reuse});
    if (revision is! String) {
      throw const SodaLibraryFailure('soda_stale_selection');
    }
    final list =
        _lists.values.where((l) => l.token == payload['list']).firstOrNull;
    final s = list?.latest;
    if (s == null || list!.current == false) {
      throw const SodaLibraryFailure('soda_stale_selection');
    }
    _Track? track;
    if (payload['snapshot'] == s.token) {
      track = s.tracks.where((t) => t.token == payload['track']).firstOrNull;
      if (track == null) {
        throw const SodaLibraryFailure('soda_invalid_selection');
      }
    } else {
      // 汽水 re-fetched this list since it was shown (the cache time moves even
      // when the songs do not), so the selection names an older copy of the
      // same list. Play that same song if it is still in the current list;
      // otherwise the selection is stale. (The library revision is not
      // compared: it changes on any cache rewrite, which made most taps from
      // the iPad quick menu fail. 2026-10-24)
      final old = list.snapshots
          .where((x) => x.token == payload['snapshot'])
          .firstOrNull;
      final picked =
          old?.tracks.where((t) => t.token == payload['track']).firstOrNull;
      if (picked == null) {
        throw const SodaLibraryFailure('soda_stale_selection');
      }
      track = s.tracks.where((t) => t.id == picked.id).firstOrNull;
      if (track == null) {
        throw const SodaLibraryFailure('soda_stale_selection');
      }
    }
    if (!track.supported) {
      throw const SodaLibraryFailure('soda_track_unavailable');
    }
    ListenTapTrace.mark('host.resolve.end', {'us': clock.elapsedMicroseconds});
    return track.id;
  }

  String _scope(String account) =>
      sha256.convert(utf8.encode('soda-v1:$account')).toString();
  String _listScope(String id) =>
      sha256.convert(utf8.encode('list:$id')).toString();
  Directory _store(String account, String list) => Directory(
      '${storageDirectory.path}${Platform.pathSeparator}${_scope(account).substring(0, 32)}'
      '${Platform.pathSeparator}${_listScope(list).substring(0, 32)}');

  Future<void> _restore(String account, _ListState list) async {
    final directory = _store(account, list.id);
    if (!await directory.exists()) return;
    try {
      final files = await directory
          .list(followLinks: false)
          .where((f) =>
              f is File &&
              RegExp(r'^[0-9]+_[A-Za-z0-9_-]+\.json$')
                  .hasMatch(f.uri.pathSegments.last))
          .take(200)
          .toList();
      final recovered = <_Snapshot>[];
      for (final entry in files) {
        final file = entry as File;
        if (await file.length() > 4 * 1024 * 1024) continue;
        final data = jsonDecode(await file.readAsString());
        if (data is! Map ||
            data['v'] != 1 ||
            data['scope'] != _scope(account) ||
            data['list'] != _listScope(list.id) ||
            data['snapshot'] is! Map) {
          continue;
        }
        final snapshot = _Snapshot.restore(data['snapshot'] as Map);
        if (snapshot == null) continue;
        snapshot.token = _token();
        for (final track in snapshot.tracks) {
          track.token = _token();
        }
        snapshot.savedOrder = data['order'] is int ? data['order'] as int : 0;
        _writeOrder = max(_writeOrder, snapshot.savedOrder);
        recovered.add(snapshot);
      }
      recovered.sort((a, b) => b.savedOrder.compareTo(a.savedOrder));
      final seen = <String>{};
      list.snapshots.addAll(recovered.where((s) => seen.add(s.fingerprint)));
    } catch (_) {
      // An unreadable older private file never replaces the coherent provider
      // response. It also never triggers source repair or writes into Soda.
    }
  }

  Future<void> _persist(
      String account, _ListState list, _Snapshot snapshot) async {
    final directory = _store(account, list.id);
    try {
      await directory.create(recursive: true);
      snapshot.savedOrder =
          max(_clock().microsecondsSinceEpoch, _writeOrder + 1);
      final data = jsonEncode({
        'v': 1,
        'scope': _scope(account),
        'list': _listScope(list.id),
        'order': snapshot.savedOrder,
        'snapshot': snapshot.privateJson()
      });
      if (utf8.encode(data).length > 4 * 1024 * 1024) {
        throw const SodaLibraryFailure('soda_history_full');
      }
      if (_retainedBytes == null) {
        var bytes = 0, entries = 0;
        await for (final item
            in storageDirectory.list(recursive: true, followLinks: false)) {
          if (++entries > 5000) {
            throw const SodaLibraryFailure('soda_history_full');
          }
          if (item is File) bytes += await item.length();
          if (bytes > historyByteLimit) {
            throw const SodaLibraryFailure('soda_history_full');
          }
        }
        _retainedBytes = bytes;
      }
      final byteCount = utf8.encode(data).length;
      if (_retainedBytes! + byteCount > historyByteLimit) {
        throw const SodaLibraryFailure('soda_history_full');
      }
      // Reserve before writing: a failed rename may leave a private temporary
      // file, which must still count against this session's storage budget.
      _retainedBytes = _retainedBytes! + byteCount;
      // Short local names avoid MAX_PATH pressure on Windows. Full scope
      // digests remain inside each file and are checked before restoration.
      final stem = '${snapshot.savedOrder}_${_token().substring(0, 16)}';
      final temporary =
          File('${directory.path}${Platform.pathSeparator}$stem.tmp');
      final finalPath = '${directory.path}${Platform.pathSeparator}$stem.json';
      if (await temporary.exists() || await File(finalPath).exists()) {
        throw const SodaLibraryFailure('soda_history_write_failed');
      }
      final output = await temporary.open(mode: FileMode.writeOnly);
      try {
        await output.writeString(data);
        await output.flush();
      } finally {
        await output.close();
      }
      await temporary.rename(finalPath);
      _writeOrder = snapshot.savedOrder;
      _storedThisSession++;
    } on SodaLibraryFailure {
      rethrow;
    } catch (_) {
      throw const SodaLibraryFailure('soda_history_write_failed');
    }
  }
}

String? _text(Object? value, int max) {
  if (value is! String || value.length > max) return null;
  final cleaned = value.replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]'), '');
  return cleaned.trim().isEmpty ? null : cleaned;
}

class _ListState {
  _ListState(this.id, this.token);
  final String id, token;
  String title = '';
  bool liked = false;
  bool current = true;
  final snapshots = <_Snapshot>[];
  _Snapshot? get latest => snapshots.firstOrNull;
}

class _Track {
  _Track(this.id, this.title, this.artist, this.duration, this.supported);
  final String id, title, artist;
  final int duration;
  final bool supported;
  String token = '';
  Map<String, Object?> json() => {
        'id': id,
        'title': title,
        'artist': artist,
        'duration': duration,
        'supported': supported
      };
}

class _Snapshot {
  _Snapshot(this.tracks, this.total, this.updatedAt);
  final List<_Track> tracks;
  final int? total;
  final String? updatedAt;
  String token = '', fingerprint = '';
  String? sourceRevision;
  int? reportedTotal;
  int rawResourceCount = 0;
  bool? sourceHasMore;
  int savedOrder = 0;
  Map<String, Object?> privateJson() => {
        'tracks': tracks.map((t) => t.json()).toList(),
        'total': total,
        'updatedAt': updatedAt,
        'provenance': {
          'source': 'soda-local-cache',
          'normalization': 1,
          'sourceRevision': sourceRevision,
          'reportedTotal': reportedTotal,
          'rawResourceCount': rawResourceCount,
          'hasMore': sourceHasMore,
        },
      };
  static _Snapshot? restore(Map data) {
    final rows = data['tracks'],
        total = data['total'],
        time = data['updatedAt'];
    if (rows is! List ||
        rows.length > 10000 ||
        (total != null && (total is! int || total < 0)) ||
        (time != null &&
            (time is! String || DateTime.tryParse(time) == null))) {
      return null;
    }
    final tracks = <_Track>[];
    final ids = <String>{};
    for (final row in rows) {
      if (row is! Map ||
          row['id'] is! String ||
          !RegExp(r'^[0-9]{1,32}$').hasMatch(row['id'] as String) ||
          _text(row['title'], 300) == null ||
          row['artist'] is! String ||
          (row['artist'] as String).length > 1100 ||
          row['duration'] is! int ||
          row['duration'] <= 0 ||
          row['supported'] is! bool ||
          !ids.add(row['id'] as String)) {
        return null;
      }
      tracks.add(_Track(
          row['id'] as String,
          row['title'] as String,
          row['artist'] as String,
          row['duration'] as int,
          row['supported'] as bool));
    }
    final snapshot = _Snapshot(tracks, total as int?, time as String?);
    final provenance = data['provenance'];
    if (provenance is! Map ||
        provenance['source'] != 'soda-local-cache' ||
        provenance['normalization'] != 1 ||
        provenance['sourceRevision'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$')
            .hasMatch(provenance['sourceRevision'] as String) ||
        provenance['rawResourceCount'] is! int ||
        provenance['rawResourceCount'] < 0 ||
        provenance['rawResourceCount'] > 10000 ||
        (provenance['reportedTotal'] != null &&
            (provenance['reportedTotal'] is! int ||
                provenance['reportedTotal'] < 0)) ||
        (provenance['hasMore'] != null && provenance['hasMore'] is! bool)) {
      return null;
    }
    snapshot.sourceRevision = provenance['sourceRevision'] as String;
    snapshot.reportedTotal = provenance['reportedTotal'] as int?;
    snapshot.rawResourceCount = provenance['rawResourceCount'] as int;
    snapshot.sourceHasMore = provenance['hasMore'] as bool?;
    snapshot.fingerprint = sha256
        .convert(utf8.encode(jsonEncode(snapshot.privateJson())))
        .toString();
    return snapshot;
  }
}
