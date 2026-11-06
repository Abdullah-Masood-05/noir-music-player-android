import 'dart:async';
import 'dart:convert';
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
import 'youtube_native.dart';

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
    YouTubeNative? youtube,
  }) : _api = DiscoverApi(keys: keys, client: client),
       _musicFolder = musicFolder,
       _audioQuery = audioQuery,
       _client = client,
       _youtube = youtube ?? YouTubeNative();

  /// YouTube on the phone (NewPipe Extractor): finds, plays and downloads
  /// songs on Android.
  final YouTubeNative _youtube;

  /// The HTTP client, also used to stream YouTube audio while it plays.
  http.Client get client => _client;

  /// Discover's requests.
  final DiscoverApi _api;

  final String? Function() _musicFolder;

  /// Shared with the API; also streams the downloads.
  final http.Client _client;

  /// Used to register freshly downloaded files with the media library so they
  /// appear in the Library/Music tab (and other apps) immediately.
  final OnAudioQuery _audioQuery;

  /// Downloaded tracks as {track key: saved file path}, as JSON.
  static const String _downloadedPrefsKey = 'downloaded_tracks';

  /// Older builds kept only the keys, without the file.
  static const String _legacyDownloadedPrefsKey = 'downloaded_track_keys';

  /// Tracks already downloaded and where they were saved (kept in sync with
  /// SharedPreferences). A track whose file is gone counts as not downloaded.
  final Map<String, String> _downloaded = {};
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

  /// Why [source] can't be played, asked the same way it's played.
  Future<StreamCheck> checkSource(ResolvedStream source) {
    final yt = source.youtube;
    if (yt == null) return checkStreamUrl(source.url);
    return checkStream(
      _client,
      source.url,
      request: youTubeStreamRequest(yt, 0, 1023, 0),
    );
  }

  /// A downloadable audio link for [videoId].
  Future<String> getDownloadUrl(String videoId) =>
      _api.resolveAudioLink(videoId);

  /// The audio stream to play [track] from, and its YouTube video. With
  /// [videoId] (a retry) that video is used again instead of searching.
  ///
  /// On Android NewPipe Extractor finds and resolves it on the phone (and
  /// [ResolvedStream.youtube] says how to fetch it); elsewhere the backend
  /// does.
  Future<ResolvedStream> resolveStream(
    DiscoveredTrack track, {
    String? videoId,
  }) async {
    if (YouTubeNative.available) {
      final audio = await _youtube.resolve(
        query: videoId == null
            ? YouTubeNative.searchQuery(track.name, track.artist)
            : null,
        videoId: videoId,
      );
      return ResolvedStream(
        videoId: audio.videoId,
        url: audio.url,
        youtube: audio,
      );
    }
    final id = videoId ?? await fetchYoutubeVideoId(track.name, track.artist);
    return ResolvedStream(videoId: id, url: await getDownloadUrl(id));
  }

  // ---------------------------------------------------------------------------
  // Download bookkeeping (de-duplication)
  // ---------------------------------------------------------------------------

  /// Loads the downloaded tracks from storage (once), then forgets any whose
  /// file has been deleted or moved since. Safe to call again to recheck.
  Future<Set<String>> loadDownloadedKeys() async {
    if (!_downloadedLoaded) {
      try {
        final prefs = await SharedPreferences.getInstance();
        _downloaded
          ..clear()
          ..addAll(decodeDownloaded(prefs.getString(_downloadedPrefsKey)));
        final legacy = prefs.getStringList(_legacyDownloadedPrefsKey);
        if (legacy != null) {
          await _migrateLegacy(legacy);
          await prefs.remove(_legacyDownloadedPrefsKey);
          await _saveDownloaded();
        }
      } catch (e) {
        _logError('Error loading downloaded tracks: $e');
      }
      _downloadedLoaded = true;
    }
    await refreshDownloaded();
    return _downloaded.keys.toSet();
  }

  /// Forgets downloads whose file is gone. Returns whether any were.
  Future<bool> refreshDownloaded() async {
    final gone = <String>[];
    for (final entry in _downloaded.entries) {
      if (!await File(entry.value).exists()) gone.add(entry.key);
    }
    if (gone.isEmpty) return false;
    gone.forEach(_downloaded.remove);
    await _saveDownloaded();
    return true;
  }

  /// Older builds stored "name-artist" keys without the file. Each key is
  /// matched to the file a download of it would have been saved as (the song
  /// name is the part before one of the "-"s); keys without one are dropped.
  Future<void> _migrateLegacy(List<String> keys) async {
    final String folder;
    try {
      folder = await downloadDirectory();
    } catch (_) {
      return;
    }
    for (final key in keys) {
      if (_downloaded.containsKey(key)) continue;
      for (var i = key.indexOf('-'); i > 0; i = key.indexOf('-', i + 1)) {
        final base = _sanitizeFileName(key.substring(0, i));
        final path = ['mp3', 'm4a']
            .map((ext) => '$folder/$base.$ext')
            .where((p) => File(p).existsSync())
            .firstOrNull;
        if (path != null) {
          _downloaded[key] = path;
          break;
        }
      }
    }
  }

  /// Whether the track was downloaded and its file is still there.
  bool isDownloaded(String key) {
    final path = _downloaded[key];
    if (path == null) return false;
    if (File(path).existsSync()) return true;
    _downloaded.remove(key);
    unawaited(_saveDownloaded());
    return false;
  }

  bool isDownloading(String key) => _inProgressKeys.contains(key);

  Future<void> _markDownloaded(String key, String path) async {
    _downloaded[key] = path;
    await _saveDownloaded();
  }

  Future<void> _saveDownloaded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_downloadedPrefsKey, jsonEncode(_downloaded));
    } catch (e) {
      _logError('Error saving downloaded tracks: $e');
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

      if (YouTubeNative.available) {
        return await _downloadWithYouTube(
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

      await _markDownloaded(key, savedUri);
      return DownloadResult.success;
    } catch (e) {
      _logError('Error downloading ${track.name}: $e');
      return DownloadResult.failed;
    } finally {
      _inProgressKeys.remove(key);
    }
  }

  /// Android: the audio is fetched from YouTube on the phone into the app's
  /// cache (with real progress), rebuilt as a normal M4A with the title,
  /// artist and cover inside, then moved into the music folder.
  Future<DownloadResult> _downloadWithYouTube(
    DiscoveredTrack track,
    String key, {
    Future<String?>? coverUrl,
    void Function(int received, int total)? onProgress,
    void Function(String message)? onError,
  }) async {
    final YouTubeAudio audio;
    try {
      audio = await _youtube.resolve(
        query: YouTubeNative.searchQuery(track.name, track.artist),
      );
    } on DiscoverException catch (e) {
      onError?.call(e.message);
      return DownloadResult.noSource;
    }
    // Look the cover up while the audio downloads.
    final cover = _coverBytes(track, coverUrl);
    final dir = '${(await getTemporaryDirectory()).path}/youtube';
    final id = 'dl${DateTime.now().microsecondsSinceEpoch}';
    final raw = '$dir/$id.part';
    final rebuilt = '$dir/$id.m4a';
    final plain = '$dir/$id.${audio.ext}';
    try {
      final File downloaded;
      try {
        downloaded = await _youtube.download(
          audio,
          path: raw,
          id: id,
          onProgress: onProgress,
        );
      } on DiscoverException catch (e) {
        onError?.call(e.message);
        return DownloadResult.failed;
      }
      File? finished;
      if (audio.ext == 'm4a') {
        try {
          finished = await _youtube.finish(
            downloaded,
            rebuilt,
            title: track.name,
            artist: track.artist,
            cover: await cover,
          );
        } catch (e) {
          // Keep the song even if it can't be rebuilt: it still plays.
          _logError('Finishing ${track.name} failed: $e');
        }
      }
      final source = finished ?? await downloaded.rename(plain);
      final saved = await saveLocalFile(source, track.name);
      if (saved == null) return DownloadResult.failed;
      await _markDownloaded(key, saved);
      return DownloadResult.success;
    } finally {
      for (final path in {raw, rebuilt, plain}) {
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
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

  /// Moves an already-downloaded [source] into the music folder, tags it when
  /// it's an MP3 and registers it with the media library. Returns the saved
  /// file path, or null on failure.
  Future<String?> saveLocalFile(
    File source,
    String rawFilename, {
    Future<void> Function(File file)? tag,
  }) async {
    try {
      final dot = source.path.lastIndexOf('.');
      final ext = dot > 0
          ? source.path.substring(dot + 1).toLowerCase()
          : 'm4a';
      final filePath = await _newFilePath(rawFilename, ext);
      // Copy, not rename: the cache and the music folder can be on
      // different storage.
      await source.copy(filePath);
      try {
        await source.delete();
      } catch (_) {}
      // Only MP3 tags are written here; M4As are tagged when rebuilt.
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
      await Id3Tagger.write(
        file,
        title: track.name,
        artist: track.artist,
        cover: await _coverBytes(track, coverUrl),
      );
    } catch (e) {
      _logError('Tagging failed for ${file.path}: $e');
    }
  }

  /// [track]'s album cover as a picture, or null when there's none.
  Future<Uint8List?> _coverBytes(
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
      return url == null ? null : await _fetchCover(url);
    } catch (_) {
      return null;
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

/// Where to play a Discover song from. [youtube] is set when the phone found
/// it on YouTube itself, and says how the link must be fetched.
class ResolvedStream {
  const ResolvedStream({
    required this.videoId,
    required this.url,
    this.youtube,
  });

  final String videoId;
  final String url;
  final YouTubeAudio? youtube;
}

/// Reads the stored {track key: file path} map.
@visibleForTesting
Map<String, String> decodeDownloaded(String? json) {
  if (json == null || json.isEmpty) return {};
  try {
    final root = jsonDecode(json);
    if (root is! Map) return {};
    return {
      for (final e in root.entries)
        if (e.key is String && e.value is String && e.value != '')
          e.key as String: e.value as String,
    };
  } on FormatException {
    return {};
  }
}
