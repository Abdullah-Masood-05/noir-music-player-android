import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';

import 'discover_api.dart' show DiscoverException, backendVideoQuery;
import 'youtube_search.dart';

/// The audio of one YouTube video, as NewPipe Extractor found it on this
/// phone.
class YouTubeAudio {
  const YouTubeAudio({
    required this.videoId,
    required this.url,
    this.title,
    this.duration,
    this.headers = const {},
    this.contentLength = -1,
    this.mime = 'audio/mp4',
    this.ext = 'm4a',
    this.post = true,
  });

  final String videoId;

  /// A direct stream link. It's tied to this phone's connection and expires
  /// after a few hours, so it's fetched again for each play.
  final String url;
  final String? title;
  final Duration? duration;

  /// Headers YouTube expects with [url] (its user agent and so on).
  final Map<String, String> headers;

  /// Size of the stream in bytes, or -1 when YouTube didn't say.
  final int contentLength;
  final String mime;

  /// File extension for a download: "m4a", or "webm" in the rare case a
  /// video has no M4A audio.
  final String ext;

  /// Whether [url] is fetched the way NewPipe's player does (a POST with a
  /// tiny body, Android), or with plain GETs (iOS).
  final bool post;
}

/// YouTube on the phone through the app's native "noir/youtube" channel.
/// Discover uses it to find, play and download songs without any API key or
/// shared quota.
///
/// On Android the channel runs NewPipe Extractor and does everything. On iOS
/// it runs YouTubeKit, which finds a video's audio and rebuilds the
/// downloaded file; searching and downloading are done here in Dart.
class YouTubeNative {
  YouTubeNative({
    MethodChannel? channel,
    EventChannel? progress,
    http.Client? client,
    bool? searchAndDownloadHere,
  }) : _channel = channel ?? const MethodChannel('noir/youtube'),
       _progress = progress ?? const EventChannel('noir/youtube/progress'),
       _client = client,
       _here = searchAndDownloadHere ?? (!kIsWeb && Platform.isIOS);

  final MethodChannel _channel;
  final EventChannel _progress;
  final http.Client? _client;
  http.Client? _ownClient;

  /// Search and download in Dart (iOS) rather than natively (Android).
  final bool _here;

  /// Downloads running here, by id, that were asked to stop.
  final Set<String> _cancelled = {};

  http.Client get _http => _client ?? (_ownClient ??= http.Client());

  /// Whether this platform has it.
  static bool get available =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// What to search YouTube for to find a song.
  static String searchQuery(String trackName, String artistName) =>
      backendVideoQuery('$trackName $artistName');

  /// The best audio of the first song matching [query], or of [videoId].
  Future<YouTubeAudio> resolve({String? query, String? videoId}) async {
    try {
      if (_here && videoId == null && query != null) {
        videoId = await YouTubeSearch(_http).videoId(query);
      }
      final map = await _channel.invokeMapMethod<String, Object?>('resolve', {
        'query': query,
        'videoId': videoId,
      });
      return parseYouTubeAudio(map);
    } on PlatformException catch (e) {
      throw DiscoverException(friendlyYouTubeError(e.message));
    } on DiscoverException {
      rethrow;
    } catch (e) {
      // The search (iOS), or a build without the native side.
      throw DiscoverException(friendlyYouTubeError('$e'));
    }
  }

  /// Saves [audio]'s stream to [path] as YouTube sends it, reporting bytes as
  /// they arrive.
  Future<File> download(
    YouTubeAudio audio, {
    required String path,
    required String id,
    void Function(int received, int total)? onProgress,
  }) async {
    if (_here) {
      _cancelled.remove(id);
      try {
        return await downloadYouTubeAudio(
          _http,
          audio,
          path,
          onProgress: onProgress,
          cancelled: () => _cancelled.contains(id),
        );
      } on DiscoverException {
        rethrow;
      } catch (e) {
        throw DiscoverException(friendlyYouTubeError('$e'));
      } finally {
        _cancelled.remove(id);
      }
    }
    StreamSubscription<dynamic>? sub;
    if (onProgress != null) {
      sub = _progress.receiveBroadcastStream().listen((event) {
        if (event is Map && event['id'] == id) {
          final received = event['received'];
          final total = event['total'];
          if (received is num && total is num) {
            onProgress(received.toInt(), total.toInt());
          }
        }
      }, onError: (Object _) {});
    }
    try {
      final saved = await _channel.invokeMethod<String>('download', {
        'url': audio.url,
        'headers': audio.headers,
        'contentLength': audio.contentLength,
        'path': path,
        'id': id,
      });
      if (saved == null) {
        throw const DiscoverException('YouTube sent no audio.');
      }
      return File(saved);
    } on PlatformException catch (e) {
      throw DiscoverException(friendlyYouTubeError(e.message));
    } finally {
      await sub?.cancel();
    }
  }

  /// Turns a downloaded M4A from [input] into a normal one at [output] with
  /// the title, artist and cover inside.
  Future<File> finish(
    File input,
    String output, {
    String? title,
    String? artist,
    Uint8List? cover,
  }) async {
    try {
      final saved = await _channel.invokeMethod<String>('finish', {
        'input': input.path,
        'output': output,
        'title': title,
        'artist': artist,
        'cover': cover,
      });
      return File(saved ?? output);
    } on PlatformException catch (e) {
      throw DiscoverException(friendlyYouTubeError(e.message));
    }
  }

  Future<void> cancel(String id) async {
    if (_here) {
      _cancelled.add(id);
      return;
    }
    try {
      await _channel.invokeMethod<void>('cancel', {'id': id});
    } catch (_) {}
  }
}

/// Plays a YouTube stream the way NewPipe's player fetches it: ranged POST
/// requests with YouTube's headers, in chunks, since one long request gets
/// slowed to playback speed and YouTube expects its apps' request shape.
class YouTubeStreamSource extends StreamAudioSource {
  YouTubeStreamSource(this.audio, this._client, {super.tag});

  final YouTubeAudio audio;
  final http.Client _client;
  int _requestNumber = 0;
  int? _length;

  static const int _chunk = 1024 * 1024;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final length = await _sourceLength();
    final from = start ?? 0;
    final to = math.min(end ?? length, length);
    return StreamAudioResponse(
      sourceLength: length,
      contentLength: math.max(0, to - from),
      offset: from,
      contentType: audio.mime,
      stream: _bytes(from, to),
    );
  }

  Future<int> _sourceLength() async {
    if (_length != null) return _length!;
    if (audio.contentLength > 0) return _length = audio.contentLength;
    // Not given: ask for the first byte and read the size from the answer.
    final response = await _client.send(
      youTubeStreamRequest(audio, 0, 0, _requestNumber++),
    );
    await response.stream.drain<void>();
    final total = int.tryParse(
      (response.headers['content-range'] ?? '').split('/').last,
    );
    if (total == null || total <= 0) {
      throw HttpException('YouTube didn\'t give the stream size');
    }
    return _length = total;
  }

  /// Bytes [from] to [to] (exclusive), one chunk per request. A chunk that
  /// fails part-way (a dropped connection) is asked for again from where it
  /// stopped, twice at most; a refusal (HTTP 4xx) ends the stream at once.
  Stream<List<int>> _bytes(int from, int to) async* {
    var position = from;
    var failures = 0;
    while (position < to) {
      final last = math.min(position + _chunk, to) - 1;
      final before = position;
      Object? error;
      try {
        final response = await _client.send(
          youTubeStreamRequest(audio, position, last, _requestNumber++),
        );
        final status = response.statusCode;
        if (status != 206 && status != 200) {
          await response.stream.drain<void>();
          throw _Refused('HTTP $status from YouTube', retry: status >= 500);
        }
        // A whole-file answer starts at byte 0: skip to the position.
        var skip = status == 200 ? position : 0;
        await for (final chunk in response.stream) {
          if (skip >= chunk.length) {
            skip -= chunk.length;
            continue;
          }
          final part = skip > 0 ? chunk.sublist(skip) : chunk;
          skip = 0;
          final room = last + 1 - position;
          if (part.length >= room) {
            yield part.sublist(0, room);
            position = last + 1;
            break;
          }
          yield part;
          position += part.length;
        }
        if (position <= last)
          throw const _Refused('YouTube stopped sending audio');
      } on _Refused catch (e) {
        if (!e.retry) rethrow;
        error = e;
      } catch (e) {
        error = e;
      }
      if (error == null) {
        failures = 0;
        continue;
      }
      if (position == before) failures++;
      if (failures > 2) throw error;
      await Future<void>.delayed(Duration(milliseconds: 400 * (failures + 1)));
    }
  }
}

class _Refused implements Exception {
  const _Refused(this.message, {this.retry = true});

  final String message;
  final bool retry;

  @override
  String toString() => message;
}

/// One ranged request for a YouTube stream link (bytes [start] to [end],
/// inclusive). On Android it's shaped like NewPipe's player sends it: a POST
/// with a tiny body and a request number. On iOS it's a plain GET.
http.Request youTubeStreamRequest(
  YouTubeAudio audio,
  int start,
  int end,
  int requestNumber,
) {
  if (!audio.post) {
    return http.Request('GET', Uri.parse(audio.url))
      ..headers.addAll(audio.headers)
      ..headers['Range'] = 'bytes=$start-$end'
      ..headers['Accept-Encoding'] = 'identity';
  }
  var url = audio.url;
  if (url.contains('/videoplayback') && !url.contains('&rn=')) {
    url = '$url&rn=$requestNumber';
  }
  return http.Request('POST', Uri.parse(url))
    ..headers.addAll(audio.headers)
    ..headers['Range'] = 'bytes=$start-$end'
    ..headers['Accept-Encoding'] = 'identity'
    ..bodyBytes = const [0x78, 0];
}

/// Reads the native side's answer for one video.
@visibleForTesting
YouTubeAudio parseYouTubeAudio(Map<String, Object?>? map) {
  if (map == null) {
    throw const DiscoverException('No matching YouTube video was found.');
  }
  final id = map['videoId'];
  final url = map['url'];
  if (id is! String || url is! String || !url.startsWith('https://')) {
    throw const DiscoverException('No playable audio was found for this song.');
  }
  final ms = map['durationMs'];
  final length = map['contentLength'];
  final headers = map['headers'];
  final mime = map['mime'];
  final ext = map['ext'];
  return YouTubeAudio(
    videoId: id,
    url: url,
    title: map['title'] is String ? map['title'] as String : null,
    duration: ms is num && ms > 0 ? Duration(milliseconds: ms.toInt()) : null,
    headers: headers is Map
        ? {
            for (final e in headers.entries)
              if (e.key is String && e.value is String)
                e.key as String: e.value as String,
          }
        : const {},
    contentLength: length is num ? length.toInt() : -1,
    mime: mime is String && mime.isNotEmpty ? mime : 'audio/mp4',
    ext: ext is String && ext.isNotEmpty ? ext : 'm4a',
    post: map['post'] != false,
  );
}

/// Saves [audio]'s stream to [path] in 1 MiB ranges, four at a time, like
/// the Android side does: one long request gets slowed to playback speed. A
/// range that fails is asked for again twice, unless YouTube refused it
/// (HTTP 4xx).
Future<File> downloadYouTubeAudio(
  http.Client client,
  YouTubeAudio audio,
  String path, {
  void Function(int received, int total)? onProgress,
  bool Function()? cancelled,
  int chunkSize = 1024 * 1024,
  int parallel = 4,
}) async {
  var requestNumber = 0;
  var total = audio.contentLength;
  if (total <= 0) {
    // Not given: ask for the first byte and read the size from the answer.
    final response = await client.send(
      youTubeStreamRequest(audio, 0, 0, requestNumber++),
    );
    await response.stream.drain<void>();
    if (response.statusCode >= 400) {
      throw HttpException('HTTP ${response.statusCode} from YouTube');
    }
    total =
        int.tryParse(
          (response.headers['content-range'] ?? '').split('/').last,
        ) ??
        -1;
    if (total <= 0) throw const HttpException('YouTube sent no audio');
  }

  final file = File(path);
  await file.parent.create(recursive: true);
  final out = await file.open(mode: FileMode.write);
  // A RandomAccessFile allows one operation at a time: writes take turns.
  var writing = Future<void>.value();
  Future<void> write(int at, List<int> bytes) {
    final next = writing.then((_) async {
      await out.setPosition(at);
      await out.writeFrom(bytes);
    });
    writing = next.catchError((Object _) {});
    return next;
  }

  final chunks = (total + chunkSize - 1) ~/ chunkSize;
  var nextChunk = 0;
  var received = 0;
  var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
  void report({bool force = false}) {
    final now = DateTime.now();
    if (!force && now.difference(lastReport).inMilliseconds < 150) return;
    lastReport = now;
    onProgress?.call(received, total);
  }

  Future<List<int>> fetch(int start, int end) async {
    for (var attempt = 0; ; attempt++) {
      if (cancelled?.call() ?? false) {
        throw const HttpException('Download cancelled.');
      }
      try {
        final response = await client
            .send(youTubeStreamRequest(audio, start, end, requestNumber++))
            .timeout(const Duration(seconds: 20));
        final status = response.statusCode;
        if (status != 206 && status != 200) {
          await response.stream.drain<void>();
          throw _Refused('HTTP $status from YouTube', retry: status >= 500);
        }
        final bytes = await response.stream.toBytes().timeout(
          const Duration(seconds: 60),
        );
        // A whole-file answer starts at byte 0.
        final from = status == 200 ? start : 0;
        final want = end - start + 1;
        if (bytes.length < from + want) {
          throw const _Refused('YouTube stopped sending audio');
        }
        return bytes.sublist(from, from + want);
      } on _Refused catch (e) {
        if (!e.retry || attempt >= 2) rethrow;
      } catch (_) {
        if (attempt >= 2) rethrow;
      }
      await Future<void>.delayed(Duration(milliseconds: 500 * (attempt + 1)));
    }
  }

  Future<void> worker() async {
    while (nextChunk < chunks) {
      final index = nextChunk++;
      final start = index * chunkSize;
      final end = math.min(start + chunkSize, total) - 1;
      final bytes = await fetch(start, end);
      await write(start, bytes);
      received += bytes.length;
      report();
    }
  }

  try {
    report(force: true);
    await Future.wait([
      for (var i = 0; i < math.min(parallel, chunks); i++) worker(),
    ]);
    await writing;
    await out.close();
    report(force: true);
    return file;
  } catch (_) {
    // Stop the other workers from starting new ranges.
    nextChunk = chunks;
    try {
      await writing;
      await out.close();
    } catch (_) {}
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
    rethrow;
  }
}

/// What a YouTube error means for the person using the app.
@visibleForTesting
String friendlyYouTubeError(String? raw) {
  final text = (raw ?? '').trim();
  final message = _friendly(text);
  if (message == null) {
    final first = _firstLine(text);
    return first.isEmpty
        ? 'Couldn\'t get this song from YouTube.'
        : 'Couldn\'t get this song from YouTube. (${_short(first)})';
  }
  // The technical reason, shortened, helps when reporting a problem.
  final first = _firstLine(text);
  final plain = message.startsWith('No ') || message == 'Download cancelled.';
  return first.isEmpty || plain ? message : '$message (${_short(first, 90)})';
}

String _firstLine(String text) => text
    .split('\n')
    .map((l) => l.trim())
    .firstWhere((l) => l.isNotEmpty, orElse: () => '');

String _short(String s, [int max = 140]) =>
    s.length > max ? '${s.substring(0, max)}…' : s;

/// The plain-language part of [friendlyYouTubeError], or null when the
/// error isn't one of the known kinds.
String? _friendly(String text) {
  final low = text.toLowerCase();
  if (low.contains('signinconfirmnotbot') ||
      low.contains('a bot') ||
      low.contains('blocked anonymous watch access') ||
      low.contains('recaptcha')) {
    return 'YouTube asked this connection to prove it isn\'t a bot. Try again '
        'in a while, or switch between Wi-Fi and mobile data.';
  }
  if (low.contains('no matching youtube video')) {
    return 'No matching YouTube video was found.';
  }
  if (low.contains('no playable audio')) {
    return 'No playable audio was found for this song.';
  }
  if (low.contains('agerestricted') || low.contains('age restricted')) {
    return 'This song\'s video is age-restricted on YouTube, so it can\'t be '
        'played without signing in. Try another song.';
  }
  if (low.contains('geographicrestriction') ||
      low.contains('regionblocked') ||
      low.contains('not available in client\'s country')) {
    return 'This song\'s video isn\'t available in your country. Try another '
        'song.';
  }
  if (low.contains('contentnotavailable') ||
      low.contains('privatecontent') ||
      low.contains('paidcontent') ||
      low.contains('musicpremium') ||
      low.contains('videounavailable') ||
      low.contains('videoprivate') ||
      low.contains('video is private') ||
      low.contains('membersonly') ||
      low.contains('members only') ||
      low.contains('video unavailable')) {
    return 'This song\'s video isn\'t available on YouTube here. Try another '
        'song.';
  }
  if (low.contains('unknownhost') ||
      low.contains('sockettimeout') ||
      low.contains('timeout') ||
      low.contains('connectexception') ||
      low.contains('unable to resolve host') ||
      low.contains('network is unreachable') ||
      low.contains('connection reset') ||
      low.contains('sslhandshake') ||
      low.contains('urlerror') ||
      low.contains('socketexception') ||
      low.contains('connection closed') ||
      low.contains('timed out') ||
      low.contains('appears to be offline') ||
      low.contains('network connection was lost')) {
    return 'Couldn\'t reach YouTube. Check your connection and try again.';
  }
  if (low.contains('http 429')) {
    return 'YouTube is limiting requests from this connection right now. Try '
        'again in a few minutes.';
  }
  if (low.contains('http 403')) {
    return 'YouTube refused the request. Try again in a few minutes; if it '
        'keeps happening, YouTube may have changed and an app update will '
        'fix it.';
  }
  if (low.contains('download cancelled')) return 'Download cancelled.';
  return null;
}
