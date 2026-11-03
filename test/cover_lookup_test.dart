// Discover artwork lookup: Deezer first, iTunes second, strict matching,
// caching, de-duplication, concurrency and back-off.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noir_player/core/services/cover_lookup.dart';
import 'package:noir_player/core/services/discover_api.dart';
import 'package:noir_player/core/state/covers.dart';
import 'package:noir_player/core/state/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _itunesArt =
    'https://is1-ssl.mzstatic.com/image/thumb/Music/ab/cd/source/100x100bb.jpg';
const _deezerMedium =
    'https://cdn-images.dzcdn.net/images/cover/abc/250x250-000000-80-0-0.jpg';
const _deezerBig =
    'https://cdn-images.dzcdn.net/images/cover/abc/500x500-000000-80-0-0.jpg';

Map<String, dynamic> _itunesSong(
  String artist,
  String title, {
  String album = 'Album',
  String art = _itunesArt,
}) => {
  'artistName': artist,
  'trackName': title,
  'collectionName': album,
  'artworkUrl100': art,
};

Map<String, dynamic> _deezerSong(String artist, String title) => {
  'title': title,
  'artist': {'name': artist},
  'album': {
    'title': 'Album',
    'cover_medium': _deezerMedium,
    'cover_big': _deezerBig,
  },
};

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  group('lookup', () {
    test('Deezer first; iTunes after a miss, with 300 / 600 px art', () async {
      final requests = <Uri>[];
      final lookup = CoverLookup(
        client: MockClient((req) async {
          requests.add(req.url);
          if (req.url.host == 'api.deezer.com') return _json({'data': []});
          return _json({
            'results': [_itunesSong('Olivia Rodrigo', 'expectations')],
          });
        }),
      );

      final cover = await lookup.coverFor(
        'Olivia Rodrigo',
        'expectations (feat. Chappell Roan)',
      );

      expect(cover, isNotNull);
      expect(cover!.thumb, contains('300x300bb'));
      expect(cover.large, contains('600x600bb'));
      expect(requests.map((u) => u.host), [
        'api.deezer.com',
        'itunes.apple.com',
      ]);
      expect(
        requests.first.queryParameters['q'],
        'Olivia Rodrigo expectations',
      );
      final q = requests.last.queryParameters;
      expect(q['term'], 'Olivia Rodrigo expectations');
      expect(q['entity'], 'song');
      expect(q['limit'], '10');
      expect(q['country'], 'us');
    });

    test('a Deezer match is used without asking iTunes', () async {
      final hosts = <String>[];
      final lookup = CoverLookup(
        client: MockClient((req) async {
          hosts.add(req.url.host);
          return _json({
            'data': [_deezerSong('Pritam', 'Aashiyan')],
          });
        }),
      );

      final cover = await lookup.coverFor('Pritam', 'Aashiyan');

      expect(hosts, ['api.deezer.com']);
      expect(cover, const Cover(thumb: _deezerMedium, large: _deezerBig));
    });

    test("Deezer's empty no-cover image is not used", () async {
      final lookup = CoverLookup(
        client: MockClient((req) async {
          if (req.url.host == 'itunes.apple.com') return _json({'results': []});
          return _json({
            'data': [
              {
                'title': 'Aashiyan',
                'artist': {'name': 'Pritam'},
                'album': {
                  'title': 'Barfi!',
                  'cover_medium':
                      'https://cdn-images.dzcdn.net/images/cover//250x250-000000-80-0-0.jpg',
                  'cover_big':
                      'https://cdn-images.dzcdn.net/images/cover//500x500-000000-80-0-0.jpg',
                },
              },
            ],
          });
        }),
      );
      expect(await lookup.coverFor('Pritam', 'Aashiyan'), isNull);
    });

    test('iTunes rate-limiting skips it for a while', () async {
      var now = DateTime(2026, 11, 3);
      final hosts = <String>[];
      final lookup = CoverLookup(
        now: () => now,
        client: MockClient((req) async {
          hosts.add(req.url.host);
          if (req.url.host == 'itunes.apple.com') return _json({}, 429);
          return _json({'data': []});
        }),
      );

      await lookup.coverFor('Clairo', 'Bags');
      await lookup.coverFor('Clairo', 'Bags 2');
      expect(hosts.where((h) => h == 'itunes.apple.com'), hasLength(1));

      now = now.add(CoverLookup.itunesBackoff + const Duration(seconds: 1));
      await lookup.coverFor('Clairo', 'Bags 3');
      expect(hosts.where((h) => h == 'itunes.apple.com'), hasLength(2));
    });

    test('Deezer quota errors back it off too', () async {
      var deezerCalls = 0;
      final lookup = CoverLookup(
        client: MockClient((req) async {
          if (req.url.host == 'itunes.apple.com') return _json({'results': []});
          deezerCalls++;
          return _json({
            'error': {'code': 4, 'message': 'Quota limit exceeded'},
          });
        }),
      );
      expect(await lookup.coverFor('A Band', 'Song One'), isNull);
      expect(await lookup.coverFor('A Band', 'Song Two'), isNull);
      expect(deezerCalls, 1);
    });

    test('a long credit is searched again with its first artist', () async {
      final terms = <String>[];
      final lookup = CoverLookup(
        client: MockClient((req) async {
          if (req.url.host != 'itunes.apple.com') return _json({'data': []});
          final term = req.url.queryParameters['term']!;
          terms.add(term);
          return term == 'Shreya Ghoshal Aashiyan'
              ? _json({
                  'results': [
                    _itunesSong(
                      'Pritam, Shreya Ghoshal & Nikhil Paul George',
                      'Aashiyan',
                    ),
                  ],
                })
              : _json({'results': []});
        }),
      );
      final cover = await lookup.coverFor(
        'Shreya Ghoshal & Nikhil Paul George',
        'Aashiyan',
      );
      expect(cover, isNotNull);
      expect(terms, [
        'Shreya Ghoshal & Nikhil Paul George Aashiyan',
        'Shreya Ghoshal Aashiyan',
      ]);
      expect(lookup.debugMatches.values.single, startsWith('itunes: Pritam'));
    });

    test('a definite miss is cached; no second request', () async {
      var calls = 0;
      final lookup = CoverLookup(
        client: MockClient((req) async {
          calls++;
          return req.url.host == 'itunes.apple.com'
              ? _json({'results': []})
              : _json({'data': []});
        }),
      );
      expect(await lookup.coverFor('Shreya Jain', 'Aashiyan'), isNull);
      expect(lookup.isKnown('Shreya Jain', 'Aashiyan'), isTrue);
      expect(await lookup.coverFor('Shreya Jain', 'Aashiyan'), isNull);
      expect(calls, 2); // iTunes + Deezer, once
    });

    test('a network failure is not cached and is retried', () async {
      var calls = 0;
      final lookup = CoverLookup(
        client: MockClient((req) async {
          calls++;
          throw http.ClientException('offline');
        }),
      );
      expect(await lookup.coverFor('Karan Aujla', 'Softly'), isNull);
      expect(lookup.isKnown('Karan Aujla', 'Softly'), isFalse);
      await lookup.coverFor('Karan Aujla', 'Softly');
      expect(calls, 4);
    });

    test('lookups of the same song share one request', () async {
      var calls = 0;
      final gate = Completer<void>();
      final lookup = CoverLookup(
        client: MockClient((req) async {
          calls++;
          await gate.future;
          return _json({
            'data': [_deezerSong('Tate McRae', 'Housewife')],
          });
        }),
      );
      final a = lookup.coverFor('Tate McRae', 'Housewife');
      final b = lookup.coverFor('Tate McRae', 'Housewife');
      gate.complete();
      expect(await a, await b);
      expect(calls, 1);
    });

    test('at most maxConcurrent lookups run at once', () async {
      var inFlight = 0;
      var peak = 0;
      final lookup = CoverLookup(
        maxConcurrent: 4,
        client: MockClient((req) async {
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          inFlight--;
          final term = req.url.queryParameters['term']!;
          return _json({
            'results': [
              _itunesSong('Artist', term.replaceFirst('Artist ', '')),
            ],
          });
        }),
      );
      final covers = await Future.wait([
        for (var i = 0; i < 10; i++) lookup.coverFor('Artist', 'Song $i'),
      ]);
      expect(covers.every((c) => c != null), isTrue);
      expect(peak, lessThanOrEqualTo(4));
    });

    test('the song about to play jumps the queue', () async {
      final order = <String>[];
      final gates = <Completer<void>>[];
      final lookup = CoverLookup(
        maxConcurrent: 1,
        client: MockClient((req) async {
          final q =
              req.url.queryParameters['q'] ?? req.url.queryParameters['term']!;
          if (req.url.host == 'api.deezer.com') order.add(q);
          final gate = Completer<void>();
          gates.add(gate);
          await gate.future;
          return req.url.host == 'api.deezer.com'
              ? _json({'data': []})
              : _json({'results': []});
        }),
      );
      final first = lookup.coverFor('Band', 'One');
      final second = lookup.coverFor('Band', 'Two');
      final playing = lookup.coverFor('Band', 'Three', urgent: true);
      // Release requests one by one until everything has finished.
      var done = false;
      Future.wait([first, second, playing]).then((_) => done = true);
      while (!done) {
        await Future<void>.delayed(Duration.zero);
        for (final g in gates) {
          if (!g.isCompleted) g.complete();
        }
      }
      expect(order, ['Band One', 'Band Three', 'Band Two']);
    });

    test(
      'a lookup whose cards all went away before it started is skipped',
      () async {
        var calls = 0;
        final gate = Completer<void>();
        final lookup = CoverLookup(
          maxConcurrent: 1,
          client: MockClient((req) async {
            calls++;
            await gate.future;
            return _json({'data': [], 'results': []});
          }),
        );
        lookup.retain('Band', 'Busy');
        final busy = lookup.coverFor('Band', 'Busy');
        lookup.retain('Band', 'Gone');
        final gone = lookup.coverFor('Band', 'Gone');
        lookup.release('Band', 'Gone'); // its card scrolled away while queued
        gate.complete();
        await busy;
        expect(await gone, isNull);
        expect(calls, 2); // Deezer + iTunes for "Busy" only
        expect(lookup.isKnown('Band', 'Gone'), isFalse); // not cached as a miss
      },
    );

    test('offline, an expired cover is still returned', () async {
      var now = DateTime(2026, 11, 3);
      var online = true;
      final lookup = CoverLookup(
        now: () => now,
        client: MockClient((req) async {
          if (!online) throw http.ClientException('offline');
          return _json({
            'data': [_deezerSong('Pritam', 'Aashiyan')],
          });
        }),
      );
      final cover = await lookup.coverFor('Pritam', 'Aashiyan');
      now = now.add(CoverLookup.hitTtl + const Duration(days: 1));
      online = false;
      expect(lookup.isKnown('Pritam', 'Aashiyan'), isFalse);
      expect(await lookup.coverFor('Pritam', 'Aashiyan'), cover);
    });

    test('Unknown Artist and empty titles are never looked up', () async {
      var calls = 0;
      final lookup = CoverLookup(
        client: MockClient((req) async {
          calls++;
          return _json({'results': []});
        }),
      );
      expect(await lookup.coverFor('Unknown Artist', 'Track 01'), isNull);
      expect(await lookup.coverFor('Someone', '   '), isNull);
      expect(calls, 0);
    });

    test('only https images from the source host are used', () async {
      final lookup = CoverLookup(
        client: MockClient((req) async {
          if (req.url.host == 'itunes.apple.com') {
            return _json({
              'results': [
                _itunesSong(
                  'Lamb',
                  'Softly',
                  art: 'http://is1-ssl.mzstatic.com/x/100x100bb.jpg',
                ),
                _itunesSong(
                  'Lamb',
                  'Softly',
                  art: 'https://evil.example.com/100x100bb.jpg',
                ),
              ],
            });
          }
          return _json({'data': []});
        }),
      );
      expect(await lookup.coverFor('Lamb', 'Softly'), isNull);
      expect(
        isAllowedImageUrl('https://a.mzstatic.com/x.jpg', 'mzstatic.com'),
        isTrue,
      );
      expect(
        isAllowedImageUrl('https://mzstatic.com.evil.io/x.jpg', 'mzstatic.com'),
        isFalse,
      );
    });
  });

  group('disk cache', () {
    test('covers survive a restart; stale misses expire', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var now = DateTime(2026, 11, 3);
      var calls = 0;
      http.Client client() => MockClient((req) async {
        calls++;
        if (req.url.host == 'itunes.apple.com') {
          return req.url.queryParameters['term'] == 'ADÉLA Nicole Kidman'
              ? _json({
                  'results': [_itunesSong('ADELA', 'Nicole Kidman')],
                })
              : _json({'results': []});
        }
        return _json({'data': []});
      });

      final first = CoverLookup(client: client(), prefs: prefs, now: () => now);
      expect(await first.coverFor('ADÉLA', 'Nicole Kidman'), isNotNull);
      expect(await first.coverFor('Nobody', 'Nothing'), isNull);
      await first.flush();
      final before = calls;

      final second = CoverLookup(
        client: client(),
        prefs: prefs,
        now: () => now,
      );
      expect(second.peek('ADÉLA', 'Nicole Kidman'), isNotNull);
      expect(second.isKnown('Nobody', 'Nothing'), isTrue);
      expect(calls, before);

      now = now.add(CoverLookup.missTtl + const Duration(hours: 1));
      expect(second.isKnown('Nobody', 'Nothing'), isFalse); // miss expired
      expect(second.peek('ADÉLA', 'Nicole Kidman'), isNotNull); // hit kept
    });

    test('nothing is written after dispose', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final gate = Completer<void>();
      final lookup = CoverLookup(
        prefs: prefs,
        client: MockClient((req) async {
          await gate.future;
          return _json({
            'data': [_deezerSong('Pritam', 'Aashiyan')],
          });
        }),
      );
      final pending = lookup.coverFor('Pritam', 'Aashiyan');
      lookup.dispose();
      gate.complete();
      await pending;
      await Future<void>.delayed(const Duration(seconds: 3));
      // dispose() saved what it had; the cover found afterwards is not saved.
      final saved = prefs.getString(CoverLookup.prefsKey);
      expect(saved == null || !saved.contains('aashiyan'), isTrue);
    });

    test('a damaged cache is discarded', () async {
      SharedPreferences.setMockInitialValues({
        CoverLookup.prefsKey: '{not json',
      });
      final prefs = await SharedPreferences.getInstance();
      final lookup = CoverLookup(
        client: MockClient((_) async => _json({'results': []})),
        prefs: prefs,
      );
      expect(lookup.isKnown('A', 'B'), isFalse);
      expect(prefs.getString(CoverLookup.prefsKey), isNull);
    });
  });

  group('matching', () {
    const art = Cover(thumb: 't', large: 'l');
    Cover? pick(
      String artist,
      String title,
      List<(String, String, String)> results,
    ) => pickMatch(artist, title, [
      for (final (a, t, album) in results)
        coverCandidate(artist: a, title: t, album: album, cover: art),
    ]);

    test('normalizing folds accents and keeps other scripts', () {
      expect(normalize('ADÉLA'), 'adela');
      expect(normalize("Ain't  In LA!"), 'ain t in la');
      expect(normalize('आशियां'), isNotEmpty);
      expect(normalize('آشیاں'), isNotEmpty);
    });

    test('featured artists and version notes are left out of titles', () {
      expect(stripTitle('expectations (feat. Chappell Roan)'), 'expectations');
      expect(stripTitle('Creep (Acoustic)'), 'Creep');
      expect(stripTitle('Song - Live at Wembley'), 'Song');
      expect(stripTitle('Song ft. Someone'), 'Song');
      expect(stripTitle('(feat. X)'), '(feat. X)'); // never empty
    });

    test('artist credits match by any named artist', () {
      expect(
        artistMatches('Pritam', 'Shreya Ghoshal, Nikhil Paul George & Pritam'),
        isTrue,
      );
      expect(artistMatches('Karan Aujla', 'Karan Aujla & Ikky'), isTrue);
      expect(artistMatches('Karan Aujla & Ikky', 'Karan Aujla'), isTrue);
      expect(artistMatches('ADÉLA', 'ADELA'), isTrue);
      expect(artistMatches('Clairo', 'Claire Jones'), isFalse);
      expect(artistMatches('Tame Impala', 'Mau P'), isFalse);
    });

    test('a different song by the right artist is rejected', () {
      expect(pick('Clairo', 'Bags', [('Clairo', 'Echo', 'Immunity')]), isNull);
      expect(
        pick('Steve Lacy', 'Oh Yeah?', [('Steve Lacy', 'nothing', 'x')]),
        isNull,
      );
    });

    test('lyric, karaoke and tribute uploads are rejected', () {
      expect(
        pick('Karan Aujla', 'Softly', [
          ('Karan Aujla', 'Softly (Lyrics)', 'Soft Serenades'),
          ('Karan Aujla', 'Softly', 'Soft Serenades Lyrics'),
        ]),
        isNull,
      );
      expect(
        pick('Karan Aujla', 'Softly', [
          ('Soft Serenades', 'Softly (Lyrics)', 'x'),
          ('Karan Aujla & Ikky', 'Softly', 'Making Memories'),
        ]),
        art,
      );
    });

    test('the original recording is preferred over a remix', () {
      const remix = Cover(thumb: 'remix', large: 'remix');
      const original = Cover(thumb: 'orig', large: 'orig');
      final chosen = pickMatch('The Killers', 'Mr. Brightside', [
        coverCandidate(
          artist: 'The Killers',
          title: 'Mr. Brightside (Remix)',
          cover: remix,
        ),
        coverCandidate(
          artist: 'The Killers',
          title: 'Mr. Brightside',
          cover: original,
        ),
      ]);
      expect(chosen, original);
      // Only a remix exists: still better than nothing.
      expect(
        pickMatch('The Killers', 'Mr. Brightside', [
          coverCandidate(
            artist: 'The Killers',
            title: 'Mr. Brightside (Remix)',
            cover: remix,
          ),
        ]),
        remix,
      );
    });

    test('similar titles that are other songs are rejected', () {
      expect(
        pick('Salute', 'softly', [
          ('salute', 'feel the same x softly (True Vision Version)', 'x'),
        ]),
        isNull,
      );
      expect(
        pick('Nusrat Fateh Ali Khan', 'Tauba', [
          ('Nusrat Fateh Ali Khan', 'Meri Tauba', 'x'),
        ]),
        isNull,
      );
      expect(
        titleMatches('Tauba Tauba', 'Tauba Tauba (From "Bad Newz")'),
        isTrue,
      );
      expect(
        titleMatches(
          'Stateside + Zara Larsson',
          'Stateside (with Zara Larsson)',
        ),
        isTrue,
      );
    });

    test('an exact title beats a longer one', () {
      const exact = Cover(thumb: 'exact', large: 'exact');
      const longer = Cover(thumb: 'longer', large: 'longer');
      expect(
        pickMatch('Band', 'Night Drive', [
          coverCandidate(
            artist: 'Band',
            title: 'Night Drive Home',
            cover: longer,
          ),
          coverCandidate(artist: 'Band', title: 'Night Drive', cover: exact),
        ]),
        exact,
      );
    });

    test('artist names are compared whole', () {
      expect(artistMatches('Simon', 'Paul Simon'), isFalse);
      expect(
        artistMatches('Pritam Chakraborty', 'Shreya Ghoshal & Pritam'),
        isTrue,
      );
      expect(
        artistMatches('Siouxsie and the Banshees', 'Siouxsie & The Banshees'),
        isTrue,
      );
      expect(artistMatches('Salim–Sulaiman', 'Salim-Sulaiman'), isTrue);
    });

    test(
      'remix, live and karaoke versions are cached apart from the original',
      () {
        final original = cacheKey('Band', 'Song');
        expect(cacheKey('Band', 'Song (Slowed + Reverb)'), isNot(original));
        expect(cacheKey('Band', 'Song (Karaoke Version)'), isNot(original));
        expect(cacheKey('Band', 'Song - Live'), isNot(original));
        expect(cacheKey('Band', 'Song (feat. Guest)'), original);
      },
    );

    test('cache keys ignore case, accents and featured artists', () {
      expect(
        cacheKey('ADÉLA', 'Nicole Kidman (feat. X)'),
        cacheKey('adela', 'nicole kidman'),
      );
      expect(cacheKey('', 'Song'), isNull);
    });

    test('the first artist of a credit is searched on its own too', () {
      expect(
        primaryArtist('Shreya Ghoshal & Nikhil Paul George'),
        'Shreya Ghoshal',
      );
      expect(primaryArtist('Pritam, Shreya Ghoshal'), 'Pritam');
      expect(primaryArtist('Pritam • From Smart Shuffle'), 'Pritam');
      expect(primaryArtist('Radiohead'), isNull);
    });

    test('search terms are cut to 100 characters', () {
      expect(searchTerm('A', 'B' * 300).length, 100);
    });
  });

  test("Last.fm's grey star counts as no image", () {
    expect(
      largestImage([
        {
          '#text':
              'https://lastfm.freetls.fastly.net/i/u/300x300/$lastFmPlaceholderHash.png',
        },
      ]),
      '',
    );
    expect(
      largestImage([
        {
          '#text':
              'https://lastfm.freetls.fastly.net/i/u/300x300/realcover.jpg',
        },
      ]),
      'https://lastfm.freetls.fastly.net/i/u/300x300/realcover.jpg',
    );
  });

  test('the cover provider resolves through the shared lookup', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final lookup = CoverLookup(
      client: MockClient(
        (_) async => _json({
          'results': [_itunesSong('Radiohead', 'Creep')],
        }),
      ),
    );
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        coverLookupProvider.overrideWithValue(lookup),
      ],
    );
    addTearDown(c.dispose);
    final sub = c.listen(
      discoverCoverProvider((artist: 'Radiohead', title: 'Creep')),
      (_, _) {},
    );
    addTearDown(sub.close);
    final cover = await c.read(
      discoverCoverProvider((artist: 'Radiohead', title: 'Creep')).future,
    );
    expect(cover?.thumb, contains('300x300bb'));
    expect(lookup.peek('Radiohead', 'Creep'), cover);
  });
}
