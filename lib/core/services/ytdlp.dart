import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'discover_api.dart' show DiscoverException, backendVideoQuery;

/// The audio of one YouTube video, as yt-dlp found it on this phone.
class YtAudio {
  const YtAudio({
    required this.videoId,
    required this.url,
    this.title,
    this.duration,
  });

  final String videoId;

  /// A direct stream link. It's tied to this phone's connection and expires
  /// after a few hours, so it's fetched again for each play.
  final String url;
  final String? title;
  final Duration? duration;
}

/// yt-dlp running on the phone (Android), through the app's native
/// "noir/ytdlp" channel. Discover uses it to find, play and download songs
/// without any API key or shared quota.
class YtDlp {
  YtDlp({MethodChannel? channel, EventChannel? progress})
    : _channel = channel ?? const MethodChannel('noir/ytdlp'),
      _progress = progress ?? const EventChannel('noir/ytdlp/progress');

  final MethodChannel _channel;
  final EventChannel _progress;

  /// Whether this platform runs yt-dlp. On iOS Discover uses the backend.
  static bool get available => !kIsWeb && Platform.isAndroid;

  /// Finds the best-matching YouTube video for a song.
  static String searchTarget(String trackName, String artistName) =>
      'ytsearch1:${backendVideoQuery('$trackName $artistName')}';

  static String videoTarget(String videoId) =>
      'https://www.youtube.com/watch?v=$videoId';

  /// The audio stream for [target]: a [searchTarget] or a [videoTarget].
  Future<YtAudio> resolve(String target) async {
    try {
      final json = await _channel.invokeMethod<String>('resolve', {
        'target': target,
      });
      return parseYtAudio(json);
    } on PlatformException catch (e) {
      throw DiscoverException(friendlyYtDlpError(e.message));
    }
  }

  /// Downloads [target]'s audio into [dir] and returns the file: an .mp3
  /// when it could be converted, otherwise the original .m4a.
  Future<File> download(
    String target, {
    required String dir,
    required String id,
    void Function(double percent)? onProgress,
  }) async {
    StreamSubscription<dynamic>? sub;
    if (onProgress != null) {
      sub = _progress.receiveBroadcastStream().listen((event) {
        if (event is Map && event['id'] == id) {
          final p = event['progress'];
          if (p is num && p >= 0) onProgress(p.toDouble());
        }
      }, onError: (Object _) {});
    }
    try {
      final path = await _channel.invokeMethod<String>('download', {
        'target': target,
        'dir': dir,
        'id': id,
        'mp3': true,
      });
      if (path == null) throw const DiscoverException('yt-dlp saved no file.');
      return File(path);
    } on PlatformException catch (e) {
      throw DiscoverException(friendlyYtDlpError(e.message));
    } finally {
      await sub?.cancel();
    }
  }

  Future<void> cancel(String id) async {
    try {
      await _channel.invokeMethod<void>('cancel', {'id': id});
    } catch (_) {}
  }
}

/// Reads yt-dlp's `--dump-json` output for one video.
@visibleForTesting
YtAudio parseYtAudio(String? json) {
  if (json == null || json.trim().isEmpty) {
    throw const DiscoverException('No matching YouTube video was found.');
  }
  final Object? root;
  try {
    root = jsonDecode(json);
  } on FormatException {
    throw const DiscoverException('yt-dlp gave an answer the app can\'t read.');
  }
  if (root is! Map<String, dynamic>) {
    throw const DiscoverException('yt-dlp gave an answer the app can\'t read.');
  }
  final id = root['id'];
  final url = root['url'];
  if (id is! String || url is! String || !url.startsWith('https://')) {
    throw const DiscoverException('No playable audio was found for this song.');
  }
  final seconds = root['duration'];
  return YtAudio(
    videoId: id,
    url: url,
    title: root['title'] is String ? root['title'] as String : null,
    duration: seconds is num
        ? Duration(milliseconds: (seconds * 1000).round())
        : null,
  );
}

/// What yt-dlp's error means for the person using the app.
@visibleForTesting
String friendlyYtDlpError(String? raw) {
  final text = (raw ?? '').trim();
  final low = text.toLowerCase();
  if (low.contains('confirm you') && low.contains('bot') ||
      low.contains('sign in to confirm')) {
    return 'YouTube asked this connection to prove it isn\'t a bot. Try again '
        'in a while, or switch between Wi-Fi and mobile data.';
  }
  if (low.contains('no matching youtube video') ||
      low.contains('no video results')) {
    return 'No matching YouTube video was found.';
  }
  if (low.contains('video unavailable') ||
      low.contains('private video') ||
      low.contains('has been removed') ||
      low.contains('not available in your country') ||
      low.contains('blocked it in your country')) {
    return 'This song\'s video isn\'t available on YouTube here. Try another '
        'song.';
  }
  if (low.contains('timed out') ||
      low.contains('name resolution') ||
      low.contains('failed to resolve') ||
      low.contains('network is unreachable') ||
      low.contains('connection refused') ||
      low.contains('connection reset') ||
      low.contains('urlopen error') ||
      low.contains('unable to download webpage')) {
    return 'Couldn\'t reach YouTube. Check your connection and try again.';
  }
  if (low.contains('http error 429') || low.contains('too many requests')) {
    return 'YouTube is limiting requests from this connection right now. Try '
        'again in a few minutes.';
  }
  if (low.contains('http error 403')) {
    return 'YouTube refused the request. Try again in a few minutes; if it '
        'keeps happening, YouTube may have changed and the next yt-dlp update '
        'will fix it.';
  }
  final first = text
      .split('\n')
      .map((l) => l.trim())
      .firstWhere((l) => l.isNotEmpty, orElse: () => '');
  final detail = first.replaceFirst(RegExp(r'^ERROR:\s*'), '');
  return detail.isEmpty
      ? 'Couldn\'t get this song from YouTube.'
      : 'Couldn\'t get this song from YouTube. '
            '(${detail.length > 140 ? '${detail.substring(0, 140)}…' : detail})';
}
