import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:on_audio_query/on_audio_query.dart' show OnAudioQuery;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/discovered_track.dart';
import '../state/library.dart';
import '../state/settings.dart';
import 'discover_api.dart';
import 'id3_tagger.dart';
import 'stream_check.dart';
import 'ytdlp.dart';

/// Outcome of a download attempt.
enum DownloadResult {
  success,
  alreadyExists,
  inProgress,
  noSource,
  failed,
  permissionDenied,
}

/// The app's Discover service. Reads the keys and music folder from Settings
/// on every call, so a change there applies straight away.
final musicDiscoveryServiceProvider = Provider<MusicDiscoveryService>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return MusicDiscoveryService(
    keys: () {
      final settings = ref.read(settingsProvider);
      return DiscoverKeys(
        lastFm: settings.lastFmApiKey,
        youtube: settings.youtubeApiKey,
        rapidApi: settings.rapidApiKey,
      );
    },
    musicFolder: () => ref.read(settingsProvider).musicFolderPath,
    audioQuery: ref.read(onAudioQueryProvider),
    client: client,
  );
});

class MusicDiscoveryService {
  MusicDiscoveryService({
    required DiscoverKeys Function() keys,
    required String? Function() musicFolder,
    required OnAudioQuery audioQuery,
    required http.Client client,
    YtDlp? ytdlp,
  }) : _api = DiscoverApi(keys: keys, client: client),
       _musicFolder = musicFolder,
       _audioQuery = audioQuery,
       _client = client,
       _ytdlp = ytdlp ?? YtDlp();

  /// yt-dlp on the phone: finds, plays and downloads songs on Android.
  final YtDlp _ytdlp;

  /// Discover's requests.
  final DiscoverApi _api;

  final String? Function() _musicFolder;

  /// Shared with the API; also streams the downloads.
  final http.Client _client;

  /// Used to register freshly downloaded files with the media library so they
  /// appear in the Library/Music tab (and other apps) immediately.
  final OnAudioQuery _audioQuery;

  static const String _downloadedPrefsKey = 'downloaded_track_keys';

  /// Keys of tracks already downloaded (kept in sync with SharedPreferences).
  final Set<String> _downloadedKeys = {};
  bool _downloadedLoaded = false;

  /// Keys of downloads currently running, to avoid concurrent duplicates.
  final Set<String> _inProgressKeys = {};

  /// Stable identity for a track, used for de-duplicating downloads.
  String trackKey(DiscoveredTrack track) => '${track.name}-${track.artist}';

  // ---------------------------------------------------------------------------
  // Discovery (Last.fm / YouTube / audio service)
  //
  // Each service is called directly when the user has entered their own key
  // for it in Settings, and through Noir Player's backend otherwise. Failures
  // throw a [DiscoverException] whose message is meant to be shown as-is.
  // ---------------------------------------------------------------------------

  /// Trending tracks.
  Future<List<DiscoveredTrack>> fetchTrendingTracks() => _api.fetchTrending();

  /// Search for tracks.
  Future<List<DiscoveredTrack>> searchTracks(String query) =>
      _api.search(query);

  /// The id of the YouTube video that best matches the track.
  Future<String> fetchYoutubeVideoId(String trackName, String artistName) =>
      _api.findVideoId(trackName, artistName);

  /// Why the audio link [url] can't be played or downloaded.
  Future<StreamCheck> checkStreamUrl(String url) => checkStream(_client, url);

  /// A downloadable audio link for [videoId].
  Future<String> getDownloadUrl(String videoId) =>
      _api.resolveAudioLink(videoId);

  /// The audio stream to play [track] from, and its YouTube video. With
  /// [videoId] (a retry) that video is used again instead of searching.
  ///
  /// On Android yt-dlp finds and resolves it on the phone; elsewhere the
  /// backend does.
  Future<({String videoId, String url})> resolveStream(
    DiscoveredTrack track, {
    String? videoId,
  }) async {
    if (YtDlp.available) {
      final audio = await _ytdlp.resolve(
        videoId != null
            ? YtDlp.videoTarget(videoId)
            : YtDlp.searchTarget(track.name, track.artist),
      );
      return (videoId: audio.videoId, url: audio.url);
    }
    final id = videoId ?? await fetchYoutubeVideoId(track.name, track.artist);
    return (videoId: id, url: await getDownloadUrl(id));
  }

  // ---------------------------------------------------------------------------
  // Download bookkeeping (de-duplication)
  // ---------------------------------------------------------------------------

  /// Load the set of already-downloaded track keys from storage (once).
  Future<Set<String>> loadDownloadedKeys() async {
    if (_downloadedLoaded) return _downloadedKeys;
    try {
      final prefs = await SharedPreferences.getInstance();
      _downloadedKeys
        ..clear()
        ..addAll(prefs.getStringList(_downloadedPrefsKey) ?? const []);
    } catch (e) {
      _logError('Error loading downloaded keys: $e');
    }
    _downloadedLoaded = true;
    return _downloadedKeys;
  }

  bool isDownloaded(String key) => _downloadedKeys.contains(key);

  bool isDownloading(String key) => _inProgressKeys.contains(key);

  Future<void> _markDownloaded(String key) async {
    if (_downloadedKeys.add(key)) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(
          _downloadedPrefsKey,
          _downloadedKeys.toList(),
        );
      } catch (e) {
        _logError('Error persisting downloaded key: $e');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Download pipeline
  // ---------------------------------------------------------------------------

  /// Full download flow with de-duplication: resolves the source, saves the
  /// MP3 and records the track so it cannot be downloaded twice.
  ///
  /// The saved file is tagged with the track's title and artist and, when
  /// [coverUrl] gives one, its album cover, so the Library shows them.
  Future<DownloadResult> downloadTrack(
    DiscoveredTrack track, {
    Future<String?>? coverUrl,
    void Function(int received, int total)? onProgress,
    void Function(String message)? onError,
  }) async {
    await loadDownloadedKeys();
    final key = trackKey(track);

    if (isDownloaded(key)) return DownloadResult.alreadyExists;
    if (!_inProgressKeys.add(key)) return DownloadResult.inProgress;

    try {
      // We write straight into the public Music folder, which needs storage
      // access. Fail fast (before hitting the network) if it isn't granted.
      if (!await _ensureWritePermission()) {
        return DownloadResult.permissionDenied;
      }

      if (YtDlp.available) {
        return await _downloadWithYtDlp(
          track,
          key,
          coverUrl: coverUrl,
          onProgress: onProgress,
          onError: onError,
        );
      }

      final String mp3Url;
      try {
        final videoId = await fetchYoutubeVideoId(track.name, track.artist);
        mp3Url = await getDownloadUrl(videoId);
      } on DiscoverException catch (e) {
        onError?.call(e.message);
        return DownloadResult.noSource;
      }

      final savedUri = await saveFile(
        mp3Url,
        track.name,
        onProgress: onProgress,
        tag: (file) => _tag(file, track, coverUrl),
      );
      if (savedUri == null) {
        final check = await checkStreamUrl(mp3Url);
        if (check.problem != StreamProblem.none) {
          onError?.call(check.message('download'));
        }
        return DownloadResult.failed;
      }

      await _markDownloaded(key);
      return DownloadResult.success;
    } catch (e) {
      _logError('Error downloading ${track.name}: $e');
      return DownloadResult.failed;
    } finally {
      _inProgressKeys.remove(key);
    }
  }

  /// Android: yt-dlp saves the audio (converted to MP3 when it can) in the
  /// app's cache, then it's moved into the music folder and tagged.
  Future<DownloadResult> _downloadWithYtDlp(
    DiscoveredTrack track,
    String key, {
    Future<String?>? coverUrl,
    void Function(int received, int total)? onProgress,
    void Function(String message)? onError,
  }) async {
    final File temp;
    try {
      final cache = await getTemporaryDirectory();
      temp = await _ytdlp.download(
        YtDlp.searchTarget(track.name, track.artist),
        dir: '${cache.path}/ytdlp',
        id: 'dl${DateTime.now().microsecondsSinceEpoch}',
        // Reported as tenths of a percent, so the bar moves smoothly.
        onProgress: (percent) => onProgress?.call((percent * 10).round(), 1000),
      );
    } on DiscoverException catch (e) {
      onError?.call(e.message);
      return DownloadResult.noSource;
    }
    final saved = await saveLocalFile(
      temp,
      track.name,
      tag: (file) => _tag(file, track, coverUrl),
    );
    if (saved == null) return DownloadResult.failed;
    await _markDownloaded(key);
    return DownloadResult.success;
  }

  /// Ensure we can write into the public Music folder.
  ///
  /// Android 11+ requires "All files access" (MANAGE_EXTERNAL_STORAGE) to write
  /// to shared directories with `dart:io`; older versions use the legacy
  /// storage permission. Requesting `manageExternalStorage` opens the system
  /// "All files access" screen.
  Future<bool> _ensureWritePermission() async {
    // iOS has no shared-storage permission: downloads go into the app's own
    // sandboxed Documents folder.
    if (Platform.isIOS) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;
    // Legacy storage permission covers Android 10 and below.
    if (await Permission.storage.request().isGranted) return true;
    // Android 11+: prompt for all-files access.
    return await Permission.manageExternalStorage.request().isGranted;
  }

  /// Resolve the folder downloads are saved into: the user-selected music
  /// folder if set, otherwise the device's default public Music directory.
  /// On iOS this is always the app's Documents/NoirPlayerDownloads folder.
  Future<String> downloadDirectory() async {
    if (Platform.isIOS) {
      final docDir = await getApplicationDocumentsDirectory();
      return '${docDir.path}/NoirPlayerDownloads';
    }
    final custom = _musicFolder();
    if (custom != null && custom.trim().isNotEmpty) return custom;
    return _defaultMusicDirectory();
  }

  /// The device's public Music directory (e.g. /storage/emulated/0/Music),
  /// derived from the external storage root so it works across devices.
  Future<String> _defaultMusicDirectory() async {
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        // .../Android/data/<pkg>/files -> storage root
        final root = ext.path.split('/Android/').first;
        if (root.isNotEmpty) return '$root/Music';
      }
    } catch (_) {}
    return '/storage/emulated/0/Music';
  }

  /// Download an MP3 from [url] straight into the music folder and register it
  /// with the media library. Returns the saved file path, or null on failure.
  Future<String?> saveFile(
    String url,
    String rawFilename, {
    Function(int received, int total)? onProgress,
    Future<void> Function(File file)? tag,
  }) async {
    try {
      final filePath = await _newFilePath(rawFilename, 'mp3');
      await _download(url, filePath, onProgress);
      // Before the media scan, so the Library reads the new tags.
      if (tag != null) await tag(File(filePath));
      await _register(filePath);
      return filePath;
    } catch (e) {
      _logError('Error saving file: $e');
      return null;
    }
  }

  /// Moves an already-downloaded [source] (from yt-dlp) into the music
  /// folder, tags it when it's an MP3 and registers it with the media
  /// library. Returns the saved file path, or null on failure.
  Future<String?> saveLocalFile(
    File source,
    String rawFilename, {
    Future<void> Function(File file)? tag,
  }) async {
    try {
      final dot = source.path.lastIndexOf('.');
      final ext = dot > 0 ? source.path.substring(dot + 1).toLowerCase() : 'm4a';
      final filePath = await _newFilePath(rawFilename, ext);
      // Copy, not rename: the cache and the music folder can be on
      // different storage.
      await source.copy(filePath);
      try {
        await source.delete();
      } catch (_) {}
      // Only MP3 tags are written; other formats keep yt-dlp's.
      if (tag != null && ext == 'mp3') await tag(File(filePath));
      await _register(filePath);
      return filePath;
    } catch (e) {
      _logError('Error saving file: $e');
      try {
        if (await source.exists()) await source.delete();
      } catch (_) {}
      return null;
    }
  }

  /// A free path in the music folder for [rawFilename] with [ext], without
  /// clobbering an existing file of the same name.
  Future<String> _newFilePath(String rawFilename, String ext) async {
    var base = _sanitizeFileName(rawFilename);
    final suffix = '.$ext';
    if (base.toLowerCase().endsWith(suffix)) {
      base = base.substring(0, base.length - suffix.length);
    }
    final folder = await downloadDirectory();
    final dir = Directory(folder);
    if (!await dir.exists()) await dir.create(recursive: true);
    var filePath = '$folder/$base$suffix';
    var n = 1;
    while (await File(filePath).exists()) {
      filePath = '$folder/$base ($n)$suffix';
      n++;
    }
    return filePath;
  }

  /// Makes a new file visible in the media library straight away (Android
  /// only; on iOS the file stays in the app's sandbox).
  Future<void> _register(String filePath) async {
    if (Platform.isIOS) return;
    try {
      await _audioQuery.scanMedia(filePath);
    } catch (e) {
      _logError('Media scan failed for $filePath: $e');
    }
  }

  /// Streams [url] into [filePath], reporting progress. Only a successful
  /// response is saved; otherwise an error page would end up as a corrupt
  /// .mp3. A partial file is removed if the download fails.
  Future<void> _download(
    String url,
    String filePath,
    Function(int received, int total)? onProgress,
  ) async {
    final response = await _client.send(http.Request('GET', Uri.parse(url)));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.drain<void>();
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
    }

    final total = response.contentLength ?? -1;
    final file = File(filePath);
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
    } catch (_) {
      await sink.close();
      if (await file.exists()) await file.delete();
      rethrow;
    }
    await sink.close();
  }

  /// Largest cover picture embedded in a download.
  static const int _maxCoverBytes = 5 * 1024 * 1024;

  /// Writes [track]'s title, artist and cover into the downloaded [file].
  /// Never fails the download: without a cover the file keeps its own.
  Future<void> _tag(
    File file,
    DiscoveredTrack track,
    Future<String?>? coverUrl,
  ) async {
    try {
      final url = track.imageUrl.isNotEmpty
          ? track.imageUrl
          : await coverUrl?.timeout(
              const Duration(seconds: 15),
              onTimeout: () => null,
            );
      await Id3Tagger.write(
        file,
        title: track.name,
        artist: track.artist,
        cover: url == null ? null : await _fetchCover(url),
      );
    } catch (e) {
      _logError('Tagging failed for ${file.path}: $e');
    }
  }

  /// The picture at [url], or null if it isn't a JPEG or PNG under 5 MB.
  Future<Uint8List?> _fetchCover(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return null;
    try {
      final response = await _client
          .get(uri)
          .timeout(const Duration(seconds: 15));
      final bytes = response.bodyBytes;
      if (response.statusCode != 200 ||
          bytes.length > _maxCoverBytes ||
          Id3Tagger.imageMime(bytes) == null) {
        return null;
      }
      return bytes;
    } catch (e) {
      _logError('Cover download failed: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Strip path separators and characters that are illegal in file names to
  /// prevent path traversal (e.g. a track named "../../evil") and write errors.
  String _sanitizeFileName(String name) {
    var clean = name
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'^[.\s]+'), '') // no leading dots/space ("..")
        .trim();
    if (clean.isEmpty) clean = 'track';
    if (clean.length > 100) clean = clean.substring(0, 100).trim();
    return clean;
  }

  void _logError(String message) {
    if (kDebugMode) debugPrint(message);
  }
}
