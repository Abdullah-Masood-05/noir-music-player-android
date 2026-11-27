// Discover's typed search: YouTube Music's ranked songs, the fallback to
// Last.fm, and playing the exact video a result came with. Mock HTTP and
// platform channels only.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noir_player/core/models/discovered_track.dart';
import 'package:noir_player/core/services/discover_api.dart';
import 'package:noir_player/core/services/music_discovery_service.dart';
import 'package:noir_player/core/services/youtube_native.dart';
import 'package:noir_player/core/services/youtube_search.dart';
import 'package:on_audio_query/on_audio_query.dart' show OnAudioQuery;

Map<String, Object?> _artistRun(String name) => {
  'text': name,
  'navigationEndpoint': {
    'browseEndpoint': {
      'browseId': 'UC$name',
      'browseEndpointContextSupportedConfigs': {
        'browseEndpointContextMusicConfig': {
          'pageType': 'MUSIC_PAGE_TYPE_ARTIST',
        },
      },
    },
  },
};

Map<String, Object?> _song({
  Object? id = 'dDRPzSM8SYs',
  Object? title = 'Enemy',
  List<Object?>? artistRuns,
  Object? thumbnails,
  bool playButton = false,
}) => {
  'musicResponsiveListItemRenderer': {
    'thumbnail': {
      'musicThumbnailRenderer': {
        'thumbnail': {
          'thumbnails':
              thumbnails ??
              [
                {
                  'url': 'https://lh3.googleusercontent.com/abc=w60-h60-l90-rj',
                  'width': 60,
                  'height': 60,
                },
                {
                  'url':
                      'https://lh3.googleusercontent.com/abc=w120-h120-l90-rj',
                  'width': 120,
                  'height': 120,
                },
              ],
        },
      },
    },
    if (playButton)
      'overlay': {
        'musicItemThumbnailOverlayRenderer': {
          'content': {
            'musicPlayButtonRenderer': {
              'playNavigationEndpoint': {
                'watchEndpoint': {'videoId': id},
              },
            },
          },
        },
      }
    else
      'playlistItemData': {'videoId': id},
    'flexColumns': [
      {
        'musicResponsiveListItemFlexColumnRenderer': {
          'text': {
            'runs': [
              {'text': title},
            ],
          },
        },
      },
      {
        'musicResponsiveListItemFlexColumnRenderer': {
          'text': {
            'runs':
                artistRuns ??
                [
                  _artistRun('Imagine Dragons'),
                  {'text': ' & '},
                  _artistRun('JID'),
                  {'text': ' • '},
                  {'text': 'Arcane'},
                ],
          },
        },
      },
    ],
  },
};

Map<String, Object?> _answer(List<Object?> items) => {
  'contents': {
    'tabbedSearchResultsRenderer': {
      'tabs': [
        {
          'tabRenderer': {
            'content': {
              'sectionListRenderer': {
                'contents': [
                  {
                    'musicShelfRenderer': {'contents': items},
                  },
                ],
              },
            },
          },
        },
      ],
    },
  },
};

/// A valid 11-character id for [n].
String _id(int n) => 'id${n.toString().padLeft(9, '0')}';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// What the backend answers to a video search.
Map<String, Object?> _videoAnswer(String id) => {
  'items': [
    {
      'id': {'videoId': id},
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseMusicSongs', () {
    test('reads a realistic answer in order', () {
      final songs = parseMusicSongs(
        _answer([
          _song(),
          _song(
            id: 'ZVYuB_Wj9Zs',
            title: 'Enemy (feat. Someone)',
            artistRuns: [_artistRun('Solo')],
          ),
          _song(
            id: 'abcdefghijk',
            title: 'Enemy',
            artistRuns: [
              {'text': 'Plain Artist'},
              {'text': ' • '},
              {'text': 'Single'},
            ],
          ),
        ]),
      );
      expect(songs.map((s) => s.youtubeVideoId), [
        'dDRPzSM8SYs',
        'ZVYuB_Wj9Zs',
        'abcdefghijk',
      ]);
      expect(songs.map((s) => s.name), [
        'Enemy',
        'Enemy (feat. Someone)',
        'Enemy',
      ]);
      expect(songs.map((s) => s.artist), [
        'Imagine Dragons, JID',
        'Solo',
        'Plain Artist',
      ]);
      expect(
        songs.first.imageUrl,
        'https://lh3.googleusercontent.com/abc=w544-h544',
      );
    });

    test('a cover on another host is kept as it is', () {
      final songs = parseMusicSongs(
        _answer([
          _song(
            thumbnails: [
              {'url': 'https://i.ytimg.com/vi/x/a.jpg', 'width': 100},
              {'url': 'https://i.ytimg.com/vi/x/b.jpg', 'width': 300},
            ],
          ),
        ]),
      );
      expect(songs.single.imageUrl, 'https://i.ytimg.com/vi/x/b.jpg');
    });

    test('insecure or missing covers become empty', () {
      final songs = parseMusicSongs(
        _answer([
          _song(
            thumbnails: [
              {
                'url': 'http://lh3.googleusercontent.com/a=w60-h60',
                'width': 60,
              },
            ],
          ),
          _song(id: 'abcdefghijk', thumbnails: <Object?>[]),
        ]),
      );
      expect(songs.map((s) => s.imageUrl), ['', '']);
    });

    test('odd input never throws', () {
      expect(parseMusicSongs(null), isEmpty);
      expect(parseMusicSongs(<String, Object?>{}), isEmpty);
      expect(parseMusicSongs(<Object?>[]), isEmpty);
      expect(parseMusicSongs('text'), isEmpty);
      expect(parseMusicSongs(42), isEmpty);
      expect(
        parseMusicSongs({'musicResponsiveListItemRenderer': 'nope'}),
        isEmpty,
      );
      final songs = parseMusicSongs(
        _answer([
          {'musicResponsiveListItemRenderer': <String, Object?>{}},
          {
            'musicResponsiveListItemRenderer': {
              'playlistItemData': {'videoId': 'dDRPzSM8SYs'},
              'flexColumns': 'wrong',
            },
          },
          {
            'musicResponsiveListItemRenderer': {
              'playlistItemData': {'videoId': 'dDRPzSM8SYs'},
              'flexColumns': [
                1,
                null,
                {'musicResponsiveListItemFlexColumnRenderer': 'x'},
              ],
            },
          },
          _song(id: 12345),
          _song(title: 7),
          // Odd thumbnails only mean no cover.
          _song(thumbnails: 'oops'),
        ]),
      );
      expect(songs, hasLength(1));
      expect(songs.single.name, 'Enemy');
      expect(songs.single.imageUrl, '');
    });

    test('skips bad ids, empty titles and missing artists', () {
      final songs = parseMusicSongs(
        _answer([
          _song(id: 'tooShort10'),
          _song(id: 'has space!!'),
          _song(id: 'twelve_chars'),
          _song(title: ''),
          _song(title: '   '),
          _song(artistRuns: <Object?>[]),
          _song(id: 'abcdefghijk'),
        ]),
      );
      expect(songs.map((s) => s.youtubeVideoId), ['abcdefghijk']);
    });

    test('takes the id from the play button when there is no item data', () {
      final songs = parseMusicSongs(_answer([_song(playButton: true)]));
      expect(songs.single.youtubeVideoId, 'dDRPzSM8SYs');
    });

    test('drops repeated ids, keeping the first', () {
      final songs = parseMusicSongs(
        _answer([
          _song(title: 'First'),
          _song(title: 'Second'),
          _song(id: 'abcdefghijk', title: 'Third'),
        ]),
      );
      expect(songs.map((s) => s.name), ['First', 'Third']);
    });

    test('stops at 20', () {
      final items = [for (var i = 0; i < 30; i++) _song(id: _id(i))];
      final songs = parseMusicSongs(_answer(items));
      expect(songs, hasLength(20));
      expect(songs.first.youtubeVideoId, _id(0));
      expect(songs.last.youtubeVideoId, _id(19));
      expect(parseMusicSongs(_answer(items), limit: 3), hasLength(3));
    });
  });

  group('YouTubeSearch.songs', () {
    test('a blank query makes no request', () async {
      var calls = 0;
      final search = YouTubeSearch(
        MockClient((_) async {
          calls++;
          return _json(_answer([_song()]));
        }),
      );
      expect(await search.songs('   '), isEmpty);
      expect(await search.songs(''), isEmpty);
      expect(calls, 0);
    });

    test('asks YouTube Music for songs and parses the answer', () async {
      late http.Request seen;
      final search = YouTubeSearch(
        MockClient((request) async {
          seen = request;
          return _json(_answer([_song()]));
        }),
      );
      final songs = await search.songs('  enemy ');
      expect(seen.url.host, 'music.youtube.com');
      final body = jsonDecode(seen.body) as Map;
      expect(body['query'], 'enemy');
      expect(body['params'], 'EgWKAQIIAWoQEAMQBBAJEAoQBRAREBAQFQ==');
      expect(seen.headers.containsKey('Cookie'), isFalse);
      expect(songs.single.name, 'Enemy');
      expect(songs.single.artist, 'Imagine Dragons, JID');
    });

    test('a long query is cut to 200 characters', () async {
      String? query;
      final search = YouTubeSearch(
        MockClient((request) async {
          query = (jsonDecode(request.body) as Map)['query'] as String;
          return _json(_answer([]));
        }),
      );
      await search.songs('a' * 500);
      expect(query, hasLength(200));
    });

    test('a failing YouTube throws', () async {
      final search = YouTubeSearch(MockClient((_) async => _json({}, 503)));
      await expectLater(search.songs('enemy'), throwsA(isA<http.ClientException>()));
    });
  });

  group('MusicDiscoveryService.searchTracks', () {
    late List<http.Request> lastFm;

    MusicDiscoveryService service(
      Future<http.Response> Function(http.Request request) youtubeAnswer,
    ) {
      lastFm = [];
      final client = MockClient((request) async {
        lastFm.add(request);
        return _json({
          'results': {
            'trackmatches': {
              'track': [
                {'name': 'From Last.fm', 'artist': 'Someone'},
              ],
            },
          },
        });
      });
      return MusicDiscoveryService(
        keys: () => DiscoverKeys(),
        musicFolder: () => null,
        audioQuery: OnAudioQuery(),
        client: client,
        songSearch: YouTubeSearch(MockClient(youtubeAnswer)),
      );
    }

    test('uses YouTube Music and leaves Last.fm alone', () async {
      final discovery = service((_) async => _json(_answer([_song()])));
      final tracks = await discovery.searchTracks('enemy');
      expect(tracks.single.name, 'Enemy');
      expect(tracks.single.youtubeVideoId, 'dDRPzSM8SYs');
      expect(lastFm, isEmpty);
    });

    test('falls back to Last.fm when YouTube Music fails', () async {
      final discovery = service((_) async => _json({}, 500));
      final tracks = await discovery.searchTracks('enemy');
      expect(tracks.single.name, 'From Last.fm');
      expect(tracks.single.youtubeVideoId, isNull);
      expect(lastFm, hasLength(1));
    });

    test('falls back to Last.fm when YouTube Music finds nothing', () async {
      final discovery = service((_) async => _json(_answer([])));
      final tracks = await discovery.searchTracks('enemy');
      expect(tracks.single.name, 'From Last.fm');
      expect(lastFm, hasLength(1));
    });
  });

  group('playing the exact video', () {
    const link = 'https://cdn.example.com/song.mp3';

    MusicDiscoveryService backend(
      Future<http.Response> Function(http.Request request) handler,
    ) => MusicDiscoveryService(
      keys: () => DiscoverKeys(),
      musicFolder: () => null,
      audioQuery: OnAudioQuery(),
      client: MockClient(handler),
    );

    test('the backend path uses the id instead of searching', () async {
      final paths = <String>[];
      final discovery = backend((request) async {
        paths.add('${request.url.path}?${request.url.query}');
        return _json({'link': link});
      });
      final stream = await discovery.resolveStream(
        DiscoveredTrack(
          name: 'Enemy',
          artist: 'Imagine Dragons, JID',
          imageUrl: '',
          youtubeVideoId: 'dDRPzSM8SYs',
        ),
      );
      expect(stream.videoId, 'dDRPzSM8SYs');
      expect(stream.url, link);
      expect(paths, ['/api/resolve?id=dDRPzSM8SYs']);
    });

    test('the backend path searches by name when the video fails', () async {
      final paths = <String>[];
      final discovery = backend((request) async {
        paths.add(request.url.path);
        if (request.url.path == '/api/video') {
          return _json(_videoAnswer('ZVYuB_Wj9Zs'));
        }
        return request.url.queryParameters['id'] == 'dDRPzSM8SYs'
            ? _json(<String, Object?>{})
            : _json({'link': link});
      });
      final stream = await discovery.resolveStream(
        DiscoveredTrack(
          name: 'Enemy',
          artist: 'Imagine Dragons',
          imageUrl: '',
          youtubeVideoId: 'dDRPzSM8SYs',
        ),
      );
      expect(stream.videoId, 'ZVYuB_Wj9Zs');
      expect(paths, ['/api/resolve', '/api/video', '/api/resolve']);
    });

    test('a track without an id is searched for as before', () async {
      final paths = <String>[];
      final discovery = backend((request) async {
        paths.add(request.url.path);
        return request.url.path == '/api/video'
            ? _json(_videoAnswer('ZVYuB_Wj9Zs'))
            : _json({'link': link});
      });
      final stream = await discovery.resolveStream(
        DiscoveredTrack(name: 'Enemy', artist: 'Someone', imageUrl: ''),
      );
      expect(stream.videoId, 'ZVYuB_Wj9Zs');
      expect(paths, ['/api/video', '/api/resolve']);
    });

    group('on the phone', () {
      const channel = MethodChannel('test/youtube_music_songs');
      late List<MethodCall> calls;
      late List<http.Request> searches;
      late Set<String> broken;

      MusicDiscoveryService phone() {
        calls = [];
        searches = [];
        broken = {};
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              final id = (call.arguments as Map)['videoId'];
              if (broken.contains(id)) {
                throw PlatformException(code: 'x', message: 'unavailable');
              }
              return {
                'videoId': id,
                'url': 'https://rr1.googlevideo.com/videoplayback',
                'contentLength': 10,
                'post': false,
              };
            });
        final client = MockClient((request) async {
          searches.add(request);
          return _json(_answer([_song(id: 'ZVYuB_Wj9Zs')]));
        });
        return MusicDiscoveryService(
          keys: () => DiscoverKeys(),
          musicFolder: () => null,
          audioQuery: OnAudioQuery(),
          client: client,
          youtube: YouTubeNative(
            channel: channel,
            client: client,
            searchAndDownloadHere: true,
          ),
        );
      }

      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      DiscoveredTrack track(String? id) => DiscoveredTrack(
        name: 'Enemy',
        artist: 'Imagine Dragons',
        imageUrl: '',
        youtubeVideoId: id,
      );

      test('resolves the known video without searching', () async {
        final discovery = phone();
        final audio = await discovery.youtubeAudio(track('dDRPzSM8SYs'));
        expect(audio.videoId, 'dDRPzSM8SYs');
        expect(searches, isEmpty);
        expect(calls, hasLength(1));
        expect(calls.single.arguments, containsPair('videoId', 'dDRPzSM8SYs'));
        // A second look-up reuses the recent one.
        await discovery.youtubeAudio(track('dDRPzSM8SYs'));
        expect(calls, hasLength(1));
      });

      test('searches by name once when that video fails', () async {
        final discovery = phone();
        broken.add('dDRPzSM8SYs');
        final audio = await discovery.youtubeAudio(track('dDRPzSM8SYs'));
        expect(audio.videoId, 'ZVYuB_Wj9Zs');
        expect(searches, hasLength(1));
        expect(calls, hasLength(2));
      });

      test('a retry of an explicit video does not search', () async {
        final discovery = phone();
        broken.add('dDRPzSM8SYs');
        await expectLater(
          discovery.youtubeAudio(track('dDRPzSM8SYs'), videoId: 'dDRPzSM8SYs'),
          throwsA(isA<DiscoverException>()),
        );
        expect(searches, isEmpty);
      });

      test('a cached name search is not reused for a track with an id', () async {
        final discovery = phone();
        final byName = await discovery.youtubeAudio(track(null));
        expect(byName.videoId, 'ZVYuB_Wj9Zs');
        calls.clear();
        final exact = await discovery.youtubeAudio(track('dDRPzSM8SYs'));
        expect(exact.videoId, 'dDRPzSM8SYs');
        expect(calls.single.arguments, containsPair('videoId', 'dDRPzSM8SYs'));
        // The exact lookup is cached now.
        calls.clear();
        await discovery.youtubeAudio(track('dDRPzSM8SYs'));
        expect(calls, isEmpty);
      });

      test('a track without an id is searched for', () async {
        final discovery = phone();
        final audio = await discovery.youtubeAudio(track(null));
        expect(audio.videoId, 'ZVYuB_Wj9Zs');
        expect(searches, hasLength(1));
      });

      test('a malformed id is ignored', () async {
        final discovery = phone();
        final audio = await discovery.youtubeAudio(track('bad id'));
        expect(audio.videoId, 'ZVYuB_Wj9Zs');
        expect(searches, hasLength(1));
      });
    });
  });
}
