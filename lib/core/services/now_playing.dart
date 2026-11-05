import 'package:audio_service/audio_service.dart';

/// What the now-playing item should become when the player reports [item]
/// at the current index, or null when nothing needs publishing.
///
/// just_audio reports the current index on every playback event, not only
/// when the song changes. Re-publishing the queue's copy each time would drop
/// what was learned since (the song's length, found once it loads, and a
/// cover found later), and without a length Android greys out the progress
/// bar in the notification, the lock screen and Live Alerts. So for the same
/// song this only adds what's new.
///
/// [loadedDuration] is the player's length for this song once it's ready
/// (null while loading, so a previous song's length is never carried over).
MediaItem? nowPlayingUpdate({
  required MediaItem? current,
  required MediaItem item,
  required Duration? loadedDuration,
}) {
  if (current == null || current.id != item.id) {
    final duration = loadedDuration ?? item.duration;
    return duration == item.duration ? item : item.copyWith(duration: duration);
  }
  final duration = loadedDuration ?? current.duration ?? item.duration;
  final artUri = current.artUri ?? item.artUri;
  if (duration == current.duration && artUri == current.artUri) return null;
  return current.copyWith(duration: duration, artUri: artUri);
}
