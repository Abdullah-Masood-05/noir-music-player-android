import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart'
    show PlayerException, PlayerInterruptedException;

import '../../core/models/discovered_track.dart';
import '../../core/services/cover_lookup.dart';
import '../../core/services/discover_api.dart';
import '../../core/services/youtube_native.dart' show YouTubeStreamSource;
import '../../core/services/music_discovery_service.dart';
import '../../core/state/covers.dart';
import '../../core/state/library.dart';
import '../../core/state/playback.dart';
import '../../core/state/settings.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/now_playing_indicator.dart';
import '../../widgets/song_artwork.dart';

class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key, required this.onNavigateToPlayer});

  final VoidCallback onNavigateToPlayer;

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen>
    with WidgetsBindingObserver {
  late final MusicDiscoveryService _discoveryService = ref.read(
    musicDiscoveryServiceProvider,
  );
  final TextEditingController _searchController = TextEditingController();

  List<DiscoveredTrack> _tracks = [];
  bool _isLoading = true;
  bool _isSearching = false;
  String? _loadingTrack;
  final Map<String, double> _downloadProgress = {};

  /// Counts plays started here; a slower, older play stops once a newer one
  /// has started.
  int _playGeneration = 0;

  String _keyFor(DiscoveredTrack t) => '${t.name}-${t.artist}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _discoveryService.loadDownloadedKeys().then((_) {
      if (mounted) setState(() {});
    });
    _loadTrending();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  /// A downloaded song may have been deleted while the app was away: recheck
  /// so its tick goes.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _recheckDownloads();
  }

  Future<void> _recheckDownloads() async {
    if (await _discoveryService.refreshDownloaded() && mounted) {
      setState(() {});
    }
  }

  Future<void> _loadTrending() async {
    setState(() => _isLoading = true);
    try {
      final tracks = await _discoveryService.fetchTrendingTracks();
      if (!mounted) return;
      setState(() {
        _tracks = tracks;
        _isLoading = false;
        _isSearching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnack(_errorText(e, 'Error loading trending'));
    }
  }

  Future<void> _searchSongs(String query) async {
    if (query.trim().isEmpty) {
      _loadTrending();
      return;
    }
    setState(() {
      _isLoading = true;
      _isSearching = true;
    });
    try {
      final tracks = await _discoveryService.searchTracks(query);
      if (!mounted) return;
      setState(() {
        _tracks = tracks;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnack(_errorText(e, 'Error searching'));
    }
  }

  Future<void> _playTrack(DiscoveredTrack track) async {
    final key = _keyFor(track);
    final generation = ++_playGeneration;
    bool superseded() => generation != _playGeneration;
    setState(() => _loadingTrack = key);
    // The lock screen, notification and player show this cover; look it up
    // while the audio link resolves.
    final cover = track.imageUrl.isEmpty
        ? ref
              .read(coverLookupProvider)
              .coverFor(track.artist, track.name, urgent: true)
        : Future<Cover?>.value(null);
    try {
      var source = await _discoveryService.resolveStream(track);

      // Play through the main player so it shows in the player / mini-player /
      // notification and is fully controllable.
      final handler = ref.read(audioHandlerProvider);
      if (handler == null) throw StateError('The audio service is not running');
      final art = track.imageUrl.isNotEmpty
          ? track.imageUrl
          : (await cover.timeout(
              const Duration(seconds: 2),
              onTimeout: () => null,
            ))?.large;
      final id = 'discover:$key';
      Future<void> play() {
        final youtube = source.youtube;
        return handler.playStream(
          id: id,
          url: source.url,
          title: track.name,
          artist: track.artist,
          artUri: art,
          source: youtube == null
              ? null
              : (item) => YouTubeStreamSource(
                  youtube,
                  _discoveryService.client,
                  tag: item,
                ),
        );
      }

      try {
        await play();
      } on PlayerInterruptedException {
        rethrow; // another song was started meanwhile
      } on PlayerException {
        // The audio server can fail for a moment, or one of its servers can
        // be down: ask for a fresh link and try once more.
        await Future<void>.delayed(const Duration(seconds: 1));
        if (superseded()) return;
        try {
          source = await _discoveryService.resolveStream(
            track,
            videoId: source.videoId,
          );
          if (superseded()) return;
          await play();
        } on PlayerInterruptedException {
          rethrow;
        } catch (_) {
          if (superseded()) return;
          // Don't leave the failed song showing as the one playing.
          await handler.clearFailedStream(id);
          final check = await _discoveryService.checkSource(source);
          throw DiscoverException(check.message('play'));
        }
      }
      if (superseded()) return;
      if (art == null) {
        // Still looking: give the playing song its cover when it arrives.
        unawaited(
          cover.then((c) {
            if (c != null) handler.setArtwork(id, Uri.parse(c.large));
          }),
        );
      }
      if (!mounted) return;
      setState(() => _loadingTrack = null);
      widget.onNavigateToPlayer();
    } on PlayerInterruptedException {
      // Another song was started before this one loaded.
      if (mounted && _loadingTrack == key) setState(() => _loadingTrack = null);
    } catch (e) {
      if (!mounted || superseded()) return;
      setState(() => _loadingTrack = null);
      _showSnack(_errorText(e, 'Error playing track'));
    } finally {
      // A newer play took over: drop this one's spinner only.
      if (mounted && superseded() && _loadingTrack == key) {
        setState(() => _loadingTrack = null);
      }
    }
  }

  Future<void> _downloadTrack(DiscoveredTrack track) async {
    final key = _keyFor(track);
    if (_discoveryService.isDownloaded(key)) {
      _showSnack('${track.name} is already downloaded');
      return;
    }
    if (_downloadProgress.containsKey(key)) return;

    setState(() => _downloadProgress[key] = 0.0);
    String? errorMessage;
    final result = await _discoveryService.downloadTrack(
      track,
      // Saved inside the file, so the Library shows the album cover.
      coverUrl: track.imageUrl.isEmpty
          ? ref
                .read(coverLookupProvider)
                .coverFor(track.artist, track.name, urgent: true)
                .then((c) => c?.large, onError: (Object _) => null)
          : null,
      onProgress: (received, total) {
        if (total > 0 && mounted) {
          setState(() => _downloadProgress[key] = received / total);
        }
      },
      onError: (message) => errorMessage = message,
    );
    if (!mounted) return;
    setState(() => _downloadProgress.remove(key));

    switch (result) {
      case DownloadResult.success:
        // Show the new file in the Library straight away.
        ref.invalidate(librarySongsProvider);
        _showSnack(
          'Saved to ${ref.read(settingsProvider).musicFolderLabel}: ${track.name}',
        );
        break;
      case DownloadResult.alreadyExists:
        _showSnack('${track.name} is already downloaded');
        break;
      case DownloadResult.noSource:
        _showSnack(
          errorMessage ?? 'No downloadable source found for ${track.name}',
        );
        break;
      case DownloadResult.failed:
        _showSnack(errorMessage ?? 'Failed to download ${track.name}');
        break;
      case DownloadResult.permissionDenied:
        _showSnack(
          'Storage access needed — allow "All files access" for Noir Player, '
          'then try again',
        );
        break;
      case DownloadResult.inProgress:
        break;
    }
  }

  /// Discover errors carry a message meant for the user; show it as-is.
  String _errorText(Object error, String fallback) =>
      error is DiscoverException ? error.message : '$fallback: $error';

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        // Longer messages explain what to try: leave time to read them.
        duration: Duration(seconds: message.length > 80 ? 8 : 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The Library reloads after songs change: recheck the ticks then too.
    ref.listen(librarySongsProvider, (_, _) => _recheckDownloads());

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: AppTheme.topFade(context),
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              const SizedBox(height: kToolbarHeight),
              _searchBar(theme),
              Expanded(child: _content(theme)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _searchBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: _searchController,
        textInputAction: TextInputAction.search,
        onSubmitted: _searchSongs,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          hintText: 'Search songs, artists…',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _searchController.clear();
                    _loadTrending();
                  },
                )
              : null,
          filled: true,
          fillColor: theme.colorScheme.surface,
          contentPadding: const EdgeInsets.symmetric(vertical: 0),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(28),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _content(ThemeData theme) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_tracks.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.music_off,
              size: 64,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.25),
            ),
            const SizedBox(height: 16),
            Text(
              _isSearching ? 'No results found' : 'No tracks available',
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 88),
      itemCount: _tracks.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Row(
              children: [
                Icon(
                  _isSearching ? Icons.search : Icons.trending_up,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  _isSearching ? 'Results' : 'Trending now',
                  style: theme.textTheme.titleMedium,
                ),
              ],
            ),
          );
        }
        final index = i - 1;
        return _trackCard(_tracks[index], index, theme);
      },
    );
  }

  Widget _trackCard(DiscoveredTrack track, int index, ThemeData theme) {
    final key = _keyFor(track);
    final isLoading = _loadingTrack == key;
    final progress = _downloadProgress[key];
    final isDownloaded = _discoveryService.isDownloaded(key);
    final primary = theme.colorScheme.primary;

    return Consumer(
      builder: (context, ref, _) {
        final isCurrent = ref.watch(isCurrentMediaProvider('discover:$key'));
        return Card(
              child: InkWell(
                onTap: isLoading
                    ? null
                    : isCurrent
                    ? widget.onNavigateToPlayer
                    : () => _playTrack(track),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      _artwork(track, theme),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              track.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontSize: 15,
                                color: isCurrent ? primary : null,
                                fontWeight: isCurrent
                                    ? FontWeight.bold
                                    : FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              track.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: 44,
                        height: 44,
                        child: Center(
                          child: isLoading
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : isCurrent
                              ? NowPlayingIndicator(color: primary, size: 20)
                              : IconButton(
                                  icon: Icon(
                                    Icons.play_circle_fill,
                                    color: primary,
                                    size: 34,
                                  ),
                                  onPressed: () => _playTrack(track),
                                ),
                        ),
                      ),
                      SizedBox(
                        width: 44,
                        height: 44,
                        child: Center(
                          child: progress != null
                              ? CircularProgressIndicator(
                                  value: progress > 0 ? progress : null,
                                  strokeWidth: 3,
                                )
                              : isDownloaded
                              ? IconButton(
                                  tooltip: 'Downloaded',
                                  icon: const Icon(
                                    Icons.download_done,
                                    color: Colors.green,
                                  ),
                                  onPressed: () => _showSnack(
                                    '${track.name} is already downloaded',
                                  ),
                                )
                              : IconButton(
                                  tooltip: 'Download',
                                  icon: const Icon(Icons.download_outlined),
                                  onPressed: () => _downloadTrack(track),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
            .animate()
            .fadeIn(duration: 250.ms, delay: (index.clamp(0, 12) * 35).ms)
            .slideX(begin: 0.06, curve: Curves.easeOut);
      },
    );
  }

  Widget _artwork(DiscoveredTrack track, ThemeData theme) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: DiscoverArtwork(track: track, size: 56),
    );
  }
}

/// A Discover track's artwork: the URL it came with, otherwise a cover looked
/// up by artist and title (shown at once when it is already cached).
class DiscoverArtwork extends ConsumerWidget {
  const DiscoverArtwork({super.key, required this.track, required this.size});

  final DiscoveredTrack track;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final placeholder = Container(
      width: size,
      height: size,
      color: theme.colorScheme.primary.withValues(alpha: 0.12),
      child: Icon(Icons.music_note, color: theme.colorScheme.primary),
    );
    if (track.imageUrl.isNotEmpty) {
      return RemoteArtwork(
        url: track.imageUrl,
        size: size,
        placeholder: placeholder,
      );
    }

    final lookup = ref.read(coverLookupProvider);
    final Cover? cover;
    if (lookup.isKnown(track.artist, track.name)) {
      cover = lookup.peek(track.artist, track.name);
    } else {
      cover = ref
          .watch(
            discoverCoverProvider((artist: track.artist, title: track.name)),
          )
          .value;
    }
    if (cover == null) return placeholder;
    return RemoteArtwork(
      url: cover.thumb,
      size: size,
      placeholder: placeholder,
    );
  }
}
