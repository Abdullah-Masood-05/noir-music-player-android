import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../services/cover_lookup.dart';
import 'settings.dart';

/// The app's [CoverLookup], with its cache kept in SharedPreferences.
final coverLookupProvider = Provider<CoverLookup>((ref) {
  final client = http.Client();
  final lookup = CoverLookup(
    client: client,
    prefs: ref.watch(sharedPreferencesProvider),
  );
  ref.onDispose(() {
    lookup.dispose();
    client.close();
  });
  return lookup;
});

/// The artwork of one Discover track, looked up when its card is shown.
final discoverCoverProvider = FutureProvider.autoDispose
    .family<Cover?, ({String artist, String title})>((ref, track) {
      final lookup = ref.read(coverLookupProvider);
      // While a card shows the song, keep its lookup; once every card for it
      // is gone, a lookup still waiting its turn is skipped.
      lookup.retain(track.artist, track.title);
      ref.onDispose(() => lookup.release(track.artist, track.title));
      return lookup.coverFor(track.artist, track.title);
    });
