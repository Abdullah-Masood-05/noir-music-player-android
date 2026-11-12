import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noir_player/core/services/discover_api.dart';
import 'package:noir_player/core/services/youtube_native.dart';
import 'package:noir_player/core/services/youtube_search.dart';

const _url =
    'https://rr3---sn-a5mekn6s.googlevideo.com/videoplayback?expire=1&c=VISIONOS';

YouTubeAudio _audio({int length = 2500000}) => YouTubeAudio(
  videoId: 'BI9HQCzpDgQ',
  url: _url,
  headers: const {'User-Agent': 'Mozilla/5.0 visionOS'},
  contentLength: length,
  post: false,
);

Uint8List _data(int n) => Uint8List.fromList(List.generate(n, (i) => i % 251));

/// A fake YouTube that serves [data] for ranged GETs and records them.
MockClient _youtube(
  Uint8List data,
  List<http.Request> seen, {
  http.Response? Function(http.Request request)? override,
}) => MockClient((request) async {
  seen.add(request);
  final special = override?.call(request);
  if (special != null) return special;
  final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(request.headers['Range']!)!;
  final start = int.parse(m.group(1)!);
  final end = int.parse(m.group(2)!).clamp(0, data.length - 1);
  return http.Response.bytes(
    data.sublist(start, end + 1),
    206,
    headers: {'content-range': 'bytes $start-$end/${data.length}'},
  );
});

/// A trimmed YouTube Music "Songs" answer.
Map<String, Object?> _musicAnswer(List<String> ids) => {
  'contents': {
    'tabbedSearchResultsRenderer': {
      'tabs': [
        {
          'tabRenderer': {
            'content': {
              'sectionListRenderer': {
                'contents': [
                  {
                    'musicShelfRenderer': {
                      'contents': [
                        for (final id in ids)
                          {
                            'musicResponsiveListItemRenderer': {
                              'flexColumns': [
                                {
                                  'musicResponsiveListItemFlexColumnRenderer': {
                                    'text': {
                                      'runs': [
                                        {'text': 'Earrings'},
                                      ],
                                    },
                                  },
                                },
                              ],
                              'playlistItemData': {'videoId': id},
                            },
                          },
                      ],
                    },
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

/// A trimmed YouTube video search answer: a Shorts shelf, then a video.
Map<String, Object?> _videoAnswer(String id) => {
  'contents': {
    'twoColumnSearchResultsRenderer': {
      'primaryContents': {
        'sectionListRenderer': {
          'contents': [
            {
              'itemSectionRenderer': {
                'contents': [
                  {
                    'reelShelfRenderer': {
                      'items': [
                        {
                          'shortsLockupViewModel': {'entityId': 'shorts-x'},
                        },
                      ],
                    },
                  },
                  {
                    'videoRenderer': {
                      'videoId': id,
                      'title': {
                        'runs': [
                          {'text': 'Malcolm Todd - Earrings'},
                        ],
                      },
                    },
                  },
                ],
              },
            },
          ],
        },
      },
    },
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('YouTube search answers', () {
    test('the first YouTube Music song', () {
      expect(
        firstMusicSongId(_musicAnswer(['BI9HQCzpDgQ', 'other'])),
        'BI9HQCzpDgQ',
      );
    });

    test('a song without playlist data uses its play button', () {
      expect(
        firstMusicSongId({
          'musicResponsiveListItemRenderer': {
            'overlay': {
              'musicItemThumbnailOverlayRenderer': {
                'content': {
                  'musicPlayButtonRenderer': {
                    'playNavigationEndpoint': {
                      'watchEndpoint': {'videoId': 'abc'},
                    },
                  },
                },
              },
            },
          },
        }),
        'abc',
      );
    });

    test('no songs', () {
      expect(firstMusicSongId(_musicAnswer([])), isNull);
      expect(firstMusicSongId({}), isNull);
    });

    test('the first video, skipping Shorts', () {
      expect(firstVideoId(_videoAnswer('S02J3QifNog')), 'S02J3QifNog');
      expect(firstVideoId({}), isNull);
    });
  });

  group('YouTubeSearch', () {
    test('asks YouTube Music for songs first', () async {
      final hosts = <String>[];
      final client = MockClient((request) async {
        hosts.add(request.url.host);
        final body = jsonDecode(request.body) as Map;
        expect(body['query'], 'Earrings Malcolm Todd');
        expect(
          (body['context'] as Map)['client'],
          containsPair('clientName', 'WEB_REMIX'),
        );
        return http.Response(jsonEncode(_musicAnswer(['BI9HQCzpDgQ'])), 200);
      });
      expect(
        await YouTubeSearch(client).videoId('Earrings Malcolm Todd'),
        'BI9HQCzpDgQ',
      );
      expect(hosts, ['music.youtube.com']);
    });

    test('falls back to a video search', () async {
      final client = MockClient((request) async {
        if (request.url.host == 'music.youtube.com') {
          return http.Response('busy', 503);
        }
        return http.Response(jsonEncode(_videoAnswer('S02J3QifNog')), 200);
      });
      expect(await YouTubeSearch(client).videoId('Earrings'), 'S02J3QifNog');
    });

    test('nothing found anywhere', () async {
      final client = MockClient(
        (request) async => http.Response(jsonEncode({}), 200),
      );
      expect(
        YouTubeSearch(client).videoId('zzzz'),
        throwsA(
          isA<DiscoverException>().having(
            (e) => e.message,
            'message',
            'No matching YouTube video was found.',
          ),
        ),
      );
    });
  });

  group('iOS stream requests', () {
    test('are plain ranged GETs with the client headers', () {
      final request = youTubeStreamRequest(_audio(), 0, 1023, 7);
      expect(request.method, 'GET');
      expect(request.url.toString(), _url);
      expect(request.headers['Range'], 'bytes=0-1023');
      expect(request.headers['User-Agent'], 'Mozilla/5.0 visionOS');
      expect(request.bodyBytes, isEmpty);
    });

    test('the native answer says how to fetch the link', () {
      final map = {'videoId': 'BI9HQCzpDgQ', 'url': _url, 'contentLength': 10};
      expect(parseYouTubeAudio({...map, 'post': false}).post, isFalse);
      expect(parseYouTubeAudio(map).post, isTrue);
    });
  });

  group('downloadYouTubeAudio', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('ytdl'));
    tearDown(() async => dir.delete(recursive: true));

    test('saves every range in place, a few at a time', () async {
      final data = _data(2500000);
      final seen = <http.Request>[];
      final progress = <int>[];
      final file = await downloadYouTubeAudio(
        _youtube(data, seen),
        _audio(length: data.length),
        '${dir.path}/song.part',
        onProgress: (received, total) {
          expect(total, data.length);
          progress.add(received);
        },
      );
      expect(await file.readAsBytes(), data);
      expect(seen, hasLength(3));
      expect(seen.every((r) => r.method == 'GET'), isTrue);
      expect(progress.last, data.length);
    });

    test('asks for the size when YouTube didn\'t give it', () async {
      final data = _data(5000);
      final seen = <http.Request>[];
      final file = await downloadYouTubeAudio(
        _youtube(data, seen),
        _audio(length: -1),
        '${dir.path}/song.part',
        chunkSize: 2048,
      );
      expect(await file.readAsBytes(), data);
      expect(seen.first.headers['Range'], 'bytes=0-0');
    });

    test('retries a range that failed', () async {
      final data = _data(3000);
      var failed = false;
      final file = await downloadYouTubeAudio(
        _youtube(
          data,
          [],
          override: (request) {
            if (failed) return null;
            failed = true;
            return http.Response('oops', 503);
          },
        ),
        _audio(length: data.length),
        '${dir.path}/song.part',
        chunkSize: 1000,
      );
      expect(await file.readAsBytes(), data);
    });

    test('stops at a refusal and leaves no file', () async {
      final path = '${dir.path}/song.part';
      final seen = <http.Request>[];
      await expectLater(
        downloadYouTubeAudio(
          _youtube(
            _data(3000),
            seen,
            override: (_) => http.Response('no', 403),
          ),
          _audio(length: 3000),
          path,
          chunkSize: 1000,
          parallel: 1,
        ),
        throwsA(isA<Object>()),
      );
      expect(seen, hasLength(1));
      expect(File(path).existsSync(), isFalse);
    });

    test('can be cancelled', () async {
      await expectLater(
        downloadYouTubeAudio(
          _youtube(_data(3000), []),
          _audio(length: 3000),
          '${dir.path}/song.part',
          cancelled: () => true,
        ),
        throwsA(
          predicate((e) => friendlyYouTubeError('$e') == 'Download cancelled.'),
        ),
      );
    });
  });

  group('YouTubeNative on iOS', () {
    test('searches here, then asks the native side for that video', () async {
      const channel = MethodChannel('test/youtube');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return {
              'videoId': (call.arguments as Map)['videoId'],
              'url': _url,
              'contentLength': 10,
              'post': false,
            };
          });
      final youtube = YouTubeNative(
        channel: channel,
        client: MockClient(
          (_) async => http.Response(jsonEncode(_musicAnswer(['abc'])), 200),
        ),
        searchAndDownloadHere: true,
      );
      final audio = await youtube.resolve(query: 'Earrings Malcolm Todd');
      expect(audio.videoId, 'abc');
      expect(audio.post, isFalse);
      expect(calls.single.arguments, containsPair('videoId', 'abc'));
    });
  });

  group('friendlyYouTubeError (iOS)', () {
    test('YouTubeKit errors', () {
      expect(
        friendlyYouTubeError('YouTubeKitError.videoAgeRestricted'),
        startsWith("This song's video is age-restricted"),
      );
      expect(
        friendlyYouTubeError('YouTubeKitError.videoRegionBlocked'),
        startsWith("This song's video isn't available in your country"),
      );
      expect(
        friendlyYouTubeError('YouTubeKitError.videoUnavailable'),
        startsWith("This song's video isn't available on YouTube here"),
      );
    });

    test('connection errors', () {
      for (final raw in [
        'URLError -1009: The Internet connection appears to be offline.',
        'URLError -1001: The request timed out.',
        'ClientException with SocketException: Connection failed',
      ]) {
        expect(friendlyYouTubeError(raw), startsWith("Couldn't reach YouTube"));
      }
    });
  });
}
