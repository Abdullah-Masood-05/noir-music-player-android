import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Album artwork for a Discover track, in a thumbnail and a large size.
@immutable
class Cover {
  const Cover({required this.thumb, required this.large});

  /// About 300 px: list cards.
  final String thumb;

  /// About 600 px: the player, mini player and lock screen.
  final String large;

  @override
  bool operator ==(Object other) =>
      other is Cover && other.thumb == thumb && other.large == large;

  @override
  int get hashCode => Object.hash(thumb, large);
}

/// Finds album artwork for Discover tracks, which arrive without any.
///
/// Looks the song up in Deezer, then the iTunes Search API, both without a
/// key (Deezer first: it allows 50 requests per 5 seconds, iTunes about 20 a
/// minute), and accepts a result only when its artist and title match the track
/// (a wrong cover is worse than none). Answers are cached in memory and on
/// disk; covers for 30 days, songs with none for 3 days, so a track is looked
/// up once. Lookups for the same song share one request, at most
/// [maxConcurrent] run at a time, and a source that rate-limits is skipped
/// for a while.
class CoverLookup {
  CoverLookup({
    required http.Client client,
    SharedPreferences? prefs,
    DateTime Function()? now,
    this.maxConcurrent = 4,
    this.timeout = const Duration(seconds: 6),
    this.country = 'us',
  }) : _client = client,
       _prefs = prefs,
       _now = now ?? DateTime.now;

  final http.Client _client;
  final SharedPreferences? _prefs;
  final DateTime Function() _now;
  final int maxConcurrent;
  final Duration timeout;

  /// iTunes storefront to search.
  final String country;

  static const prefsKey = 'discover.covers.v1';
  static const maxEntries = 2000;
  static const hitTtl = Duration(days: 30);
  static const missTtl = Duration(days: 3);
  static const itunesBackoff = Duration(minutes: 10);
  static const deezerBackoff = Duration(seconds: 30);

  /// Changes are written at most this long after the first unsaved one.
  static const maxSaveDelay = Duration(seconds: 10);

  /// Answers by [cacheKey], least recently used first (map literals keep
  /// insertion order). A null cover is a song
  /// both sources had nothing for.
  Map<String, _Entry>? _cache;
  final Map<String, Future<Cover?>> _inFlight = {};
  int _active = 0;
  final Queue<Completer<void>> _waiting = Queue();
  DateTime? _itunesBlockedUntil;
  DateTime? _deezerBlockedUntil;
  Timer? _saveTimer;
  DateTime? _dirtySince;
  bool _disposed = false;

  /// How many shown cards want each song's cover ([retain] / [release]).
  final Map<String, int> _interest = {};

  /// Songs whose cards all went away before their lookup started.
  final Set<String> _abandoned = {};

  /// Songs being looked up for playback, which are never abandoned.
  final Set<String> _urgent = {};

  /// The cached answer for a song without looking it up: a [Cover], or null
  /// when there is none cached (or it is known to have none). [isKnown] tells
  /// the two apart.
  Cover? peek(String artist, String title) {
    final key = cacheKey(artist, title);
    if (key == null) return null;
    return _fresh(key, touch: false)?.cover;
  }

  /// Whether [peek] has a cached answer (a cover or a known miss).
  bool isKnown(String artist, String title) {
    final key = cacheKey(artist, title);
    return key != null && _fresh(key, touch: false) != null;
  }

  /// The artwork for a song, or null when none can be found (or the network
  /// is down). Never throws.
  ///
  /// [urgent] lookups (the song about to play) jump the queue and are never
  /// abandoned.
  Future<Cover?> coverFor(String artist, String title, {bool urgent = false}) {
    final key = cacheKey(artist, title);
    if (key == null) return Future.value(null);
    final cached = _fresh(key);
    if (cached != null) return Future.value(cached.cover);
    if (urgent) {
      _urgent.add(key);
      _abandoned.remove(key);
    }
    // The callback must not return the removed future: whenComplete would
    // then wait for itself.
    return _inFlight[key] ??= _lookup(key, artist, title, urgent: urgent)
        .whenComplete(() {
          _inFlight.remove(key);
          _urgent.remove(key);
        });
  }

  /// A card showing this song's cover appeared.
  void retain(String artist, String title) {
    final key = cacheKey(artist, title);
    if (key == null) return;
    _interest[key] = (_interest[key] ?? 0) + 1;
    _abandoned.remove(key);
  }

  /// A card showing this song's cover went away. When no card is left, a
  /// lookup still waiting for its turn is skipped.
  void release(String artist, String title) {
    final key = cacheKey(artist, title);
    if (key == null) return;
    final left = (_interest[key] ?? 1) - 1;
    if (left > 0) {
      _interest[key] = left;
    } else {
      _interest.remove(key);
      _abandoned.add(key);
    }
  }

  Future<Cover?> _lookup(
    String key,
    String artist,
    String title, {
    required bool urgent,
  }) async {
    await _acquire(front: urgent);
    try {
      // Every card that wanted it scrolled away while it waited.
      if (_abandoned.contains(key) && !_urgent.contains(key)) {
        _abandoned.remove(key);
        return null;
      }
      var unreachable = false;
      // Search with the whole credit first; long multi-artist credits often
      // find nothing, so try the first artist alone too. Results are still
      // matched against the whole credit.
      final first = primaryArtist(artist);
      final queries = [artist, if (first != null) first];
      for (final source in [_deezer, _itunes]) {
        for (final query in queries) {
          final result = await source(query, artist, title);
          if (result.cover != null) {
            _store(key, result.cover);
            return result.cover;
          }
          if (result.failed) {
            unreachable = true;
            break; // this source is down or rate-limited; try the next one
          }
        }
      }
      // Only a definite "no match" is remembered; a network failure is tried
      // again next time, keeping an expired cover meanwhile.
      if (!unreachable) {
        _store(key, null);
        return null;
      }
      return _cache?[key]?.cover;
    } catch (e) {
      debugPrint('Cover lookup failed for $key: $e');
      return null;
    } finally {
      _release();
    }
  }

  // ── Sources ──────────────────────────────────────────────────────────────

  Future<_SourceResult> _itunes(
    String query,
    String artist,
    String title,
  ) async {
    final blocked = _itunesBlockedUntil;
    if (blocked != null && _now().isBefore(blocked)) {
      return const _SourceResult.failed();
    }
    final uri = Uri.https('itunes.apple.com', '/search', {
      'term': searchTerm(query, title),
      'entity': 'song',
      'limit': '10',
      'country': country,
    });
    final body = await _getJson(
      uri,
      onRateLimit: () {
        _itunesBlockedUntil = _now().add(itunesBackoff);
      },
    );
    if (body == null) return const _SourceResult.failed();
    final results = body['results'];
    if (results is! List) return const _SourceResult.none();

    final candidates = <_Candidate>[];
    for (final r in results) {
      if (r is! Map) continue;
      final art = r['artworkUrl100'];
      if (art is! String || !isAllowedImageUrl(art, 'mzstatic.com')) continue;
      candidates.add(
        _Candidate(
          artist: '${r['artistName'] ?? ''}',
          title: '${r['trackName'] ?? ''}',
          album: '${r['collectionName'] ?? ''}',
          cover: Cover(
            thumb: art.replaceFirst('100x100bb', '300x300bb'),
            large: art.replaceFirst('100x100bb', '600x600bb'),
          ),
        ),
      );
    }
    return _SourceResult.of(_pick('itunes', artist, title, candidates));
  }

  Future<_SourceResult> _deezer(
    String query,
    String artist,
    String title,
  ) async {
    final blocked = _deezerBlockedUntil;
    if (blocked != null && _now().isBefore(blocked)) {
      return const _SourceResult.failed();
    }
    final uri = Uri.https('api.deezer.com', '/search', {
      'q': searchTerm(query, title),
      'limit': '10',
    });
    final body = await _getJson(
      uri,
      onRateLimit: () {
        _deezerBlockedUntil = _now().add(deezerBackoff);
      },
    );
    if (body == null) return const _SourceResult.failed();
    final error = body['error'];
    if (error is Map) {
      // Code 4: quota exceeded (50 requests per 5 seconds).
      if (error['code'] == 4) _deezerBlockedUntil = _now().add(deezerBackoff);
      return const _SourceResult.failed();
    }
    final data = body['data'];
    if (data is! List) return const _SourceResult.none();

    final candidates = <_Candidate>[];
    for (final d in data) {
      if (d is! Map) continue;
      final album = d['album'];
      final art = d['artist'];
      if (album is! Map) continue;
      final thumb = album['cover_medium'];
      final large = album['cover_big'] ?? thumb;
      if (thumb is! String || large is! String) continue;
      if (!isAllowedImageUrl(thumb, 'dzcdn.net') ||
          !isAllowedImageUrl(large, 'dzcdn.net') ||
          isDeezerPlaceholder(thumb)) {
        continue;
      }
      candidates.add(
        _Candidate(
          artist: art is Map ? '${art['name'] ?? ''}' : '',
          title: '${d['title'] ?? ''}',
          album: '${album['title'] ?? ''}',
          cover: Cover(thumb: thumb, large: large),
        ),
      );
    }
    return _SourceResult.of(_pick('deezer', artist, title, candidates));
  }

  /// What each looked-up song was matched to ("itunes: Artist - Title"), for
  /// tests and audits.
  @visibleForTesting
  final Map<String, String> debugMatches = {};

  Cover? _pick(
    String source,
    String artist,
    String title,
    List<_Candidate> candidates,
  ) {
    final cover = pickMatch(artist, title, candidates);
    if (cover != null) {
      final c = candidates.firstWhere((c) => identical(c.cover, cover));
      debugMatches['$artist - $title'] = '$source: ${c.artist} - ${c.title}';
    }
    return cover;
  }

  /// A JSON object from [uri], or null on any failure.
  Future<Map<String, dynamic>?> _getJson(
    Uri uri, {
    required void Function() onRateLimit,
  }) async {
    try {
      final response = await _client.get(uri).timeout(timeout);
      if (response.statusCode == 403 || response.statusCode == 429) {
        onRateLimit();
        return null;
      }
      if (response.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      return body is Map<String, dynamic> ? body : null;
    } catch (_) {
      return null;
    }
  }

  // ── Concurrency ──────────────────────────────────────────────────────────

  Future<void> _acquire({bool front = false}) async {
    if (_active < maxConcurrent) {
      _active++;
      return;
    }
    final waiter = Completer<void>();
    front ? _waiting.addFirst(waiter) : _waiting.add(waiter);
    await waiter.future; // the slot is handed over by _release
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _active--;
    }
  }

  // ── Cache ────────────────────────────────────────────────────────────────

  Map<String, _Entry> get _entries => _cache ??= _load();

  /// The entry for [key] if it has not expired. An expired entry stays (an
  /// expired cover is still shown if the refresh cannot reach the network)
  /// until a new answer replaces it. [touch] marks it recently used.
  _Entry? _fresh(String key, {bool touch = true}) {
    final entries = _entries;
    final entry = entries[key];
    if (entry == null) return null;
    final ttl = entry.cover == null ? missTtl : hitTtl;
    if (_now().difference(entry.storedAt) > ttl) return null;
    if (touch) {
      entries.remove(key);
      entries[key] = entry; // most recently used
    }
    return entry;
  }

  void _store(String key, Cover? cover) {
    final entries = _entries;
    entries.remove(key);
    entries[key] = _Entry(cover, _now());
    while (entries.length > maxEntries) {
      entries.remove(entries.keys.first);
    }
    _scheduleSave();
  }

  Map<String, _Entry> _load() {
    final map = <String, _Entry>{};
    final raw = _prefs?.getString(prefsKey);
    if (raw == null) return map;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('not a map');
      decoded.forEach((key, value) {
        if (key is! String || value is! Map) return;
        final ts = value['ts'];
        if (ts is! int) return;
        final storedAt = DateTime.fromMillisecondsSinceEpoch(ts);
        final thumb = value['t'];
        final large = value['l'];
        map[key] = _Entry(
          thumb is String && large is String
              ? Cover(thumb: thumb, large: large)
              : null,
          storedAt,
        );
      });
    } catch (e) {
      debugPrint('Discarding the cover cache: $e');
      _prefs?.remove(prefsKey);
      map.clear();
    }
    return map;
  }

  void _scheduleSave() {
    if (_prefs == null || _disposed) return;
    final since = _dirtySince ??= _now();
    _saveTimer?.cancel();
    if (_now().difference(since) >= maxSaveDelay) {
      unawaited(flush());
      return;
    }
    _saveTimer = Timer(const Duration(seconds: 2), flush);
  }

  /// Writes the cache to disk now (it is otherwise written shortly after a
  /// change).
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    _dirtySince = null;
    final prefs = _prefs;
    final cache = _cache;
    if (prefs == null || cache == null || _disposed) return;
    final json = <String, Object>{
      for (final e in cache.entries)
        e.key: {
          'ts': e.value.storedAt.millisecondsSinceEpoch,
          if (e.value.cover != null) 't': e.value.cover!.thumb,
          if (e.value.cover != null) 'l': e.value.cover!.large,
        },
    };
    await prefs.setString(prefsKey, jsonEncode(json));
  }

  void dispose() {
    unawaited(flush());
    _disposed = true;
  }
}

class _Entry {
  _Entry(this.cover, this.storedAt);
  final Cover? cover;
  final DateTime storedAt;
}

class _SourceResult {
  const _SourceResult.failed() : cover = null, failed = true;
  const _SourceResult.none() : cover = null, failed = false;
  const _SourceResult.of(this.cover) : failed = false;

  final Cover? cover;

  /// The source could not be asked (network, rate limit, bad answer).
  final bool failed;
}

class _Candidate {
  const _Candidate({
    required this.artist,
    required this.title,
    required this.album,
    required this.cover,
  });

  final String artist;
  final String title;
  final String album;
  final Cover cover;
}

// ── Matching ───────────────────────────────────────────────────────────────

const Map<String, String> _foldedLetters = {
  'à': 'a',
  'á': 'a',
  'â': 'a',
  'ã': 'a',
  'ä': 'a',
  'å': 'a',
  'ā': 'a',
  'ă': 'a',
  'ą': 'a',
  'æ': 'ae',
  'ç': 'c',
  'ć': 'c',
  'č': 'c',
  'ď': 'd',
  'đ': 'd',
  'è': 'e',
  'é': 'e',
  'ê': 'e',
  'ë': 'e',
  'ē': 'e',
  'ė': 'e',
  'ę': 'e',
  'ě': 'e',
  'ì': 'i',
  'í': 'i',
  'î': 'i',
  'ï': 'i',
  'ī': 'i',
  'į': 'i',
  'ı': 'i',
  'ł': 'l',
  'ñ': 'n',
  'ń': 'n',
  'ň': 'n',
  'ò': 'o',
  'ó': 'o',
  'ô': 'o',
  'õ': 'o',
  'ö': 'o',
  'ø': 'o',
  'ō': 'o',
  'ő': 'o',
  'œ': 'oe',
  'ř': 'r',
  'ś': 's',
  'š': 's',
  'ş': 's',
  'ß': 'ss',
  'ť': 't',
  'ţ': 't',
  'ù': 'u',
  'ú': 'u',
  'û': 'u',
  'ü': 'u',
  'ū': 'u',
  'ů': 'u',
  'ű': 'u',
  'ý': 'y',
  'ÿ': 'y',
  'ž': 'z',
  'ź': 'z',
  'ż': 'z',
};

final RegExp _notWordChars = RegExp(r'[^\p{L}\p{M}\p{N}]+', unicode: true);

/// Lower case, accents folded (ADÉLA → adela), punctuation and symbols turned
/// into single spaces. Letters of any script are kept.
@visibleForTesting
String normalize(String s) {
  final lower = s.toLowerCase();
  final folded = StringBuffer();
  for (final rune in lower.runes) {
    final ch = String.fromCharCode(rune);
    folded.write(_foldedLetters[ch] ?? ch);
  }
  return folded.toString().replaceAll(_notWordChars, ' ').trim();
}

const String _variantWords =
    r'remix|mix|live|acoustic|version|edit|sped|slowed|reverb|lyrics?|karaoke|'
    r'instrumental|remaster(?:ed)?|official|video|audio|cover|lofi|lo-fi';

final RegExp _featuring = RegExp(
  r'\s*[\(\[]\s*(?:feat|ft|featuring|with|from)\b[^\)\]]*[\)\]]'
  r'|\s+(?:feat\.?|ft\.?|featuring)\s+.*$'
  r'|\s+\+\s+.*$',
  caseSensitive: false,
);
final RegExp _variantBrackets = RegExp(
  r'\s*[\(\[][^\)\]]*\b(?:' + _variantWords + r')\b[^\)\]]*[\)\]]',
  caseSensitive: false,
);
final RegExp _variantDash = RegExp(
  r'\s+[-–—]\s+[^-–—]*\b(?:' + _variantWords + r')\b.*$',
  caseSensitive: false,
);

/// The title without featured artists and version notes
/// ("expectations (feat. Chappell Roan)" → "expectations").
@visibleForTesting
String stripTitle(String title) {
  var t = title.replaceAll(_featuring, '');
  t = t.replaceAll(_variantBrackets, '');
  t = t.replaceAll(_variantDash, '');
  t = t.trim();
  return t.isEmpty ? title.trim() : t;
}

final RegExp _variantTitle = RegExp(
  r'\b(?:remix|live|acoustic|sped|slowed|reverb|instrumental|karaoke|lofi|'
  r'version|remaster(?:ed)?|mashup)\b',
  caseSensitive: false,
);
final RegExp _junk = RegExp(
  r'\b(?:karaoke|lyrics?|tribute|made famous|in the style of|instrumental)\b',
  caseSensitive: false,
);

/// What separates the artists of a credit: commas, &, +, /, ;, a bullet,
/// " x ", feat., ft., featuring, and, with.
const String _creditSeparators =
    r'\s*(?:,|&|\+|/|;|•|\bx\b|\bfeat\.?|\bft\.?|\bfeaturing\b|\band\b|\bwith\b)\s*';

/// The first artist of a multi-artist credit, as written, or null for a
/// single artist ("Shreya Ghoshal & Nikhil Paul George" → "Shreya Ghoshal").
@visibleForTesting
String? primaryArtist(String artist) {
  final parts = artist
      .split(RegExp(_creditSeparators, caseSensitive: false))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
  return parts.length > 1 ? parts.first : null;
}

/// The separate artists in a credit ("Karan Aujla & Ikky", "A, B feat. C").
@visibleForTesting
List<String> artistNames(String artist) {
  return artist
      .split(RegExp(_creditSeparators, caseSensitive: false))
      .map(normalize)
      .where((n) => n.isNotEmpty)
      .toList();
}

/// Whether a result's artist credit names one of the requested artists
/// ("Pritam" matches "Shreya Ghoshal, Nikhil Paul George & Pritam"). Names
/// are compared whole ("Simon" is not "Paul Simon"); a longer form of a name
/// counts ("Pritam Chakraborty" is "Pritam").
@visibleForTesting
bool artistMatches(String requested, String result) {
  final wanted = artistNames(requested);
  final found = artistNames(result);
  if (wanted.isEmpty || found.isEmpty) return false;
  if (wanted.join(' ') == found.join(' ')) return true;
  for (final w in wanted) {
    for (final f in found) {
      if (w == f) return true;
      if (w.length >= 3 &&
          f.length >= 3 &&
          (w.startsWith('$f ') || f.startsWith('$w '))) {
        return true;
      }
    }
  }
  return false;
}

/// Whether two titles are the same song: equal once featured artists and
/// version notes are removed, or one contains the other as whole words that
/// make up more than half of it ("Softly" is not "Feel the Same x Softly").
@visibleForTesting
bool titleMatches(String requested, String result) {
  final a = normalize(stripTitle(requested));
  final b = normalize(stripTitle(result));
  if (a.isEmpty || b.isEmpty) return false;
  if (a == b) return true;
  if (a.length < 3 || b.length < 3) return false;
  final (short, long) = a.length <= b.length ? (a, b) : (b, a);
  if (!' $long '.contains(' $short ')) return false;
  final shortWords = short.split(' ').length;
  final longWords = long.split(' ').length;
  return shortWords * 2 > longWords;
}

bool _sameTitle(String requested, String result) =>
    normalize(stripTitle(requested)) == normalize(stripTitle(result));

/// The cover of the first result that is the requested song, preferring one
/// that is the same kind of recording (no remix for an original). Lyric
/// videos, karaoke and tribute versions are never accepted.
@visibleForTesting
Cover? pickMatch(String artist, String title, List<dynamic> candidates) {
  final wantVariant = _variantTitle.hasMatch(title);
  final wantJunk = _junk.hasMatch(title);
  // Best first: exact title and same kind of recording, then exact title,
  // then a close title of the same kind, then any close title.
  Cover? exactOther;
  Cover? closeSame;
  Cover? closeOther;
  for (final c in candidates.cast<_Candidate>()) {
    if (!wantJunk && (_junk.hasMatch(c.title) || _junk.hasMatch(c.album))) {
      continue;
    }
    if (!artistMatches(artist, c.artist) || !titleMatches(title, c.title)) {
      continue;
    }
    final sameKind = _variantTitle.hasMatch(c.title) == wantVariant;
    if (_sameTitle(title, c.title)) {
      if (sameKind) return c.cover;
      exactOther ??= c.cover;
    } else if (sameKind) {
      closeSame ??= c.cover;
    } else {
      closeOther ??= c.cover;
    }
  }
  return exactOther ?? closeSame ?? closeOther;
}

/// Test helper: a candidate as a source would produce it.
@visibleForTesting
Object coverCandidate({
  required String artist,
  required String title,
  String album = '',
  required Cover cover,
}) => _Candidate(artist: artist, title: title, album: album, cover: cover);

/// The search text sent to a source: the artist and the plain title,
/// at most 100 characters.
@visibleForTesting
String searchTerm(String artist, String title) {
  final term = '${artist.trim()} ${stripTitle(title)}'.trim();
  return term.length > 100 ? term.substring(0, 100) : term;
}

/// The cache key of a song, or null when there is nothing to look up
/// (no title, or no known artist).
@visibleForTesting
String? cacheKey(String artist, String title) {
  final a = normalize(artist);
  final t = normalize(stripTitle(title));
  if (a.isEmpty || t.isEmpty || a == 'unknown artist') return null;
  // A remix, live, karaoke or lyric upload gets a cover of its own, apart
  // from the original's.
  final kind =
      '${_variantTitle.hasMatch(title) ? 'v' : ''}'
      '${_junk.hasMatch(title) ? 'j' : ''}';
  return kind.isEmpty ? '$a|$t' : '$a|$t|$kind';
}

/// Deezer's image for an album without a cover (an empty picture id).
@visibleForTesting
bool isDeezerPlaceholder(String url) => url.contains('/cover//');

/// Only HTTPS images from the source's own image host are used.
@visibleForTesting
bool isAllowedImageUrl(String url, String hostSuffix) {
  final uri = Uri.tryParse(url);
  return uri != null &&
      uri.scheme == 'https' &&
      (uri.host == hostSuffix || uri.host.endsWith('.$hostSuffix'));
}
