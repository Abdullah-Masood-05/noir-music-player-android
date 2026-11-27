import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/discovered_track.dart';
import 'discover_api.dart' show DiscoverException, backendVideoQuery;

/// Finds a song's YouTube video by asking YouTube itself, the way its own
/// website does (the "InnerTube" API), with no key or quota. Used on iOS;
/// on Android NewPipe Extractor searches.
///
/// YouTube Music's "Songs" results come first: they're the official audio,
/// without video intros. When that finds nothing, a normal YouTube search
/// for videos is used.
class YouTubeSearch {
  YouTubeSearch(this._client);

  final http.Client _client;

  static const _timeout = Duration(seconds: 15);
  static const _userAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
      '(KHTML, like Gecko) Version/18.5 Safari/605.1.15';

  /// The id of the first song or video matching [query].
  Future<String> videoId(String query) async {
    Object? musicError;
    try {
      final id = firstMusicSongId(
        await _search(
          'music.youtube.com',
          'WEB_REMIX',
          '1.20251103.01.00',
          query,
          // "Songs" filter.
          'EgWKAQIIAWoQEAMQBBAJEAoQBRAREBAQFQ%3D%3D',
        ),
      );
      if (id != null) return id;
    } catch (e) {
      musicError = e;
      if (kDebugMode) debugPrint('YouTube Music search failed: $e');
    }
    final Map<String, Object?> videos;
    try {
      videos = await _search(
        'www.youtube.com',
        'WEB',
        '2.20251103.01.00',
        query,
        // "Videos" filter.
        'EgIQAQ%3D%3D',
      );
    } catch (e) {
      throw musicError ?? e;
    }
    final id = firstVideoId(videos);
    if (id == null) {
      throw const DiscoverException('No matching YouTube video was found.');
    }
    return id;
  }

  /// The songs YouTube Music lists for [query], in its own order (popular
  /// first), at most 20. Throws when YouTube can't be reached.
  Future<List<DiscoveredTrack>> songs(String query) async {
    final clean = backendVideoQuery(query);
    if (clean.isEmpty) return [];
    return parseMusicSongs(
      await _search(
        'music.youtube.com',
        'WEB_REMIX',
        '1.20251103.01.00',
        clean,
        // "Songs" filter.
        'EgWKAQIIAWoQEAMQBBAJEAoQBRAREBAQFQ%3D%3D',
      ),
    );
  }

  Future<Map<String, Object?>> _search(
    String host,
    String clientName,
    String clientVersion,
    String query,
    String params,
  ) async {
    final response = await _client
        .post(
          Uri.https(host, '/youtubei/v1/search', {'prettyPrint': 'false'}),
          headers: {
            'Content-Type': 'application/json',
            'User-Agent': _userAgent,
            'Origin': 'https://$host',
            'Referer': 'https://$host/',
            'X-YouTube-Client-Name': clientName == 'WEB' ? '1' : '67',
            'X-YouTube-Client-Version': clientVersion,
          },
          body: jsonEncode({
            'context': {
              'client': {
                'clientName': clientName,
                'clientVersion': clientVersion,
                'hl': 'en',
              },
            },
            'query': query,
            'params': Uri.decodeComponent(params),
          }),
        )
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw http.ClientException(
        'HTTP ${response.statusCode} from YouTube search',
      );
    }
    final root = jsonDecode(utf8.decode(response.bodyBytes));
    if (root is! Map<String, Object?>) {
      throw const FormatException('Unexpected YouTube search answer');
    }
    return root;
  }
}

/// The first song in a YouTube Music search answer, or null.
@visibleForTesting
String? firstMusicSongId(Map<String, Object?> root) {
  for (final item in _findAll(root, 'musicResponsiveListItemRenderer')) {
    final playlistData = item['playlistItemData'];
    if (playlistData is Map && playlistData['videoId'] is String) {
      return playlistData['videoId'] as String;
    }
    // Older answers only had it in the play button.
    final id = _firstString(item, 'videoId');
    if (id != null) return id;
  }
  return null;
}

final RegExp _songIdPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');

/// The songs in a YouTube Music search answer, in the order listed, without
/// repeats and at most [limit]. Items that don't look right are skipped; odd
/// input never throws.
@visibleForTesting
List<DiscoveredTrack> parseMusicSongs(Object? root, {int limit = 20}) {
  final songs = <DiscoveredTrack>[];
  final seen = <String>{};
  for (final item in _findAll(root, 'musicResponsiveListItemRenderer')) {
    if (songs.length >= limit) break;
    try {
      final id = _songVideoId(item);
      if (id == null || seen.contains(id)) continue;
      final columns = _list(item['flexColumns']);
      final title = _columnRuns(
        columns.isNotEmpty ? columns[0] : null,
      ).map(_runText).join().trim();
      if (title.isEmpty) continue;
      final artist = _songArtist(
        _columnRuns(columns.length > 1 ? columns[1] : null),
      );
      if (artist.isEmpty) continue;
      seen.add(id);
      songs.add(
        DiscoveredTrack(
          name: title,
          artist: artist,
          imageUrl: _songCover(item) ?? '',
          youtubeVideoId: id,
        ),
      );
    } catch (_) {
      // A shape we don't know: skip just this item.
    }
  }
  return songs;
}

List<Object?> _list(Object? node) => node is List ? node : const [];

Object? _at(Object? node, List<String> path) {
  var current = node;
  for (final key in path) {
    if (current is! Map) return null;
    current = current[key];
  }
  return current;
}

String _runText(Object? run) {
  final text = run is Map ? run['text'] : null;
  return text is String ? text : '';
}

List<Object?> _columnRuns(Object? column) => _list(
  _at(column, const [
    'musicResponsiveListItemFlexColumnRenderer',
    'text',
    'runs',
  ]),
);

String? _songVideoId(Map<Object?, Object?> item) {
  for (final candidate in [
    _at(item, const ['playlistItemData', 'videoId']),
    _at(item, const [
      'overlay',
      'musicItemThumbnailOverlayRenderer',
      'content',
      'musicPlayButtonRenderer',
      'playNavigationEndpoint',
      'watchEndpoint',
      'videoId',
    ]),
  ]) {
    if (candidate is String && _songIdPattern.hasMatch(candidate)) {
      return candidate;
    }
  }
  return null;
}

/// The linked artists in the second column, joined with ", "; without links,
/// the column's first text.
String _songArtist(List<Object?> runs) {
  final names = <String>[];
  for (final run in runs) {
    final type = _at(run, const [
      'navigationEndpoint',
      'browseEndpoint',
      'browseEndpointContextSupportedConfigs',
      'browseEndpointContextMusicConfig',
      'pageType',
    ]);
    final text = _runText(run).trim();
    if (type == 'MUSIC_PAGE_TYPE_ARTIST' && text.isNotEmpty) names.add(text);
  }
  if (names.isNotEmpty) return names.join(', ');
  return runs.isEmpty ? '' : _runText(runs.first).trim();
}

/// The largest thumbnail, as a square picture when it's served by Google.
String? _songCover(Map<Object?, Object?> item) {
  final thumbs = _list(
    _at(item, const [
      'thumbnail',
      'musicThumbnailRenderer',
      'thumbnail',
      'thumbnails',
    ]),
  );
  Map<Object?, Object?>? best;
  num bestWidth = -1;
  for (final thumb in thumbs) {
    if (thumb is! Map || thumb['url'] is! String) continue;
    final width = thumb['width'];
    final w = width is num ? width : 0;
    if (best == null || w >= bestWidth) {
      best = thumb;
      bestWidth = w;
    }
  }
  if (best == null) return null;
  final uri = Uri.tryParse(best['url'] as String);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  if (uri.host.endsWith('googleusercontent.com')) {
    final text = uri.toString();
    final sized = RegExp(r'=w\d+-h\d+[^/?#=]*$').firstMatch(text);
    if (sized != null) {
      return '${text.substring(0, sized.start)}=w544-h544';
    }
  }
  return uri.toString();
}

/// The first video in a YouTube search answer, or null. Shorts and ads use
/// other renderers, so they're skipped.
@visibleForTesting
String? firstVideoId(Map<String, Object?> root) {
  for (final video in _findAll(root, 'videoRenderer')) {
    final id = video['videoId'];
    if (id is String && id.isNotEmpty) return id;
  }
  return null;
}

/// Every map under [key] in [node], in document order.
Iterable<Map<Object?, Object?>> _findAll(Object? node, String key) sync* {
  if (node is Map) {
    for (final entry in node.entries) {
      final value = entry.value;
      if (entry.key == key && value is Map) {
        yield value;
      } else {
        yield* _findAll(value, key);
      }
    }
  } else if (node is List) {
    for (final item in node) {
      yield* _findAll(item, key);
    }
  }
}

String? _firstString(Object? node, String key) {
  if (node is Map) {
    for (final entry in node.entries) {
      if (entry.key == key && entry.value is String) {
        return entry.value as String;
      }
      final found = _firstString(entry.value, key);
      if (found != null) return found;
    }
  } else if (node is List) {
    for (final item in node) {
      final found = _firstString(item, key);
      if (found != null) return found;
    }
  }
  return null;
}
