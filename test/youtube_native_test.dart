import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noir_player/core/services/discover_api.dart';
import 'package:noir_player/core/services/music_discovery_service.dart';
import 'package:noir_player/core/services/youtube_native.dart';

const _url =
    'https://rr5---sn-2uja-aixel.googlevideo.com/videoplayback?expire=1&c=ANDROID';

YouTubeAudio _audio({int length = 2500000}) => YouTubeAudio(
  videoId: 'SQdgdWayPhQ',
  url: _url,
  headers: const {'User-Agent': 'com.google.android.youtube/20'},
  contentLength: length,
);

/// A fake YouTube that serves [data] for ranged POSTs and records them.
MockClient _youtube(Uint8List data, List<http.Request> seen) => MockClient((
  request,
) async {
  seen.add(request);
  final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(request.headers['Range']!)!;
  final start = int.parse(m.group(1)!);
  final end = int.parse(m.group(2)!).clamp(0, data.length - 1);
  return http.Response.bytes(
    data.sublist(start, end + 1),
    206,
    headers: {'content-range': 'bytes $start-$end/${data.length}'},
  );
});

Uint8List _data(int n) => Uint8List.fromList(List.generate(n, (i) => i % 251));

Future<List<int>> _read(Stream<List<int>> s) async =>
    (await s.toList()).expand((c) => c).toList();

void main() {
  group('parseYouTubeAudio', () {
    test("reads the native side's answer", () {
      final audio = parseYouTubeAudio({
        'videoId': 'SQdgdWayPhQ',
        'title': 'Clairo - Softly',
        'durationMs': 185000,
        'url': _url,
        'headers': {'User-Agent': 'ua', 'Bad': 3},
        'contentLength': 2984113,
        'mime': 'audio/mp4',
        'ext': 'm4a',
      });
      expect(audio.videoId, 'SQdgdWayPhQ');
      expect(audio.title, 'Clairo - Softly');
      expect(audio.duration, const Duration(seconds: 185));
      expect(audio.headers, {'User-Agent': 'ua'});
      expect(audio.contentLength, 2984113);
      expect(audio.ext, 'm4a');
    });

    test('defaults for missing fields', () {
      final a = parseYouTubeAudio({'videoId': 'x', 'url': 'https://a/b'});
      expect(a.duration, isNull);
      expect(a.headers, isEmpty);
      expect(a.contentLength, -1);
      expect(a.mime, 'audio/mp4');
      expect(a.ext, 'm4a');
    });

    test('nothing playable is a clear error', () {
      for (final bad in <Map<String, Object?>?>[
        null,
        {},
        {'videoId': 'x'},
        {'videoId': 'x', 'url': 'http://insecure'},
        {'url': 'https://a/b'},
      ]) {
        expect(
          () => parseYouTubeAudio(bad),
          throwsA(isA<DiscoverException>()),
          reason: '$bad',
        );
      }
    });
  });

  group('friendlyYouTubeError', () {
    test('bot check', () {
      expect(
        friendlyYouTubeError(
          'SignInConfirmNotBotException: YouTube probably temporarily blocked '
          'anonymous watch access with this IP',
        ),
        contains("prove it isn't a bot"),
      );
      expect(
        friendlyYouTubeError(
          'ReCaptchaException: reCaptcha Challenge requested',
        ),
        contains("prove it isn't a bot"),
      );
    });

    test('unavailable videos and regions', () {
      expect(
        friendlyYouTubeError('ContentNotAvailableException: Got error'),
        contains("isn't available on YouTube"),
      );
      expect(
        friendlyYouTubeError('GeographicRestrictionException: not available'),
        contains('your country'),
      );
      expect(
        friendlyYouTubeError('AgeRestrictedContentException: age'),
        contains('age-restricted'),
      );
    });

    test('connection problems', () {
      for (final raw in [
        'UnknownHostException: Unable to resolve host "www.youtube.com"',
        'SocketTimeoutException: timeout',
        'ConnectException: Failed to connect',
      ]) {
        expect(friendlyYouTubeError(raw), contains("Couldn't reach YouTube"));
      }
    });

    test('HTTP refusals', () {
      expect(
        friendlyYouTubeError('IOException: HTTP 403 from YouTube'),
        contains('refused'),
      );
      expect(
        friendlyYouTubeError('IOException: HTTP 429 from YouTube'),
        contains('limiting'),
      );
    });

    test('anything else keeps its first line, shortened', () {
      expect(
        friendlyYouTubeError(null),
        "Couldn't get this song from YouTube.",
      );
      expect(
        friendlyYouTubeError('ParsingException: odd\nmore'),
        "Couldn't get this song from YouTube. (ParsingException: odd)",
      );
      expect(friendlyYouTubeError('x' * 300), endsWith('…)'));
    });
  });

  test('youTubeStreamRequest is shaped like NewPipe sends it', () {
    final r = youTubeStreamRequest(_audio(), 10, 20, 3);
    expect(r.method, 'POST');
    expect(r.url.toString(), '$_url&rn=3');
    expect(r.headers['Range'], 'bytes=10-20');
    expect(r.headers['User-Agent'], 'com.google.android.youtube/20');
    expect(r.bodyBytes, [0x78, 0]);
    // A link that already has a request number keeps it.
    final again = youTubeStreamRequest(
      YouTubeAudio(videoId: 'x', url: '$_url&rn=9'),
      0,
      1,
      4,
    );
    expect(again.url.toString(), '$_url&rn=9');
  });

  group('YouTubeStreamSource', () {
    test('serves a range in 1 MiB requests', () async {
      final data = _data(2500000);
      final seen = <http.Request>[];
      final source = YouTubeStreamSource(_audio(), _youtube(data, seen));
      final r = await source.request(100, 2400000);
      expect(r.sourceLength, 2500000);
      expect(r.offset, 100);
      expect(r.contentLength, 2399900);
      expect(r.contentType, 'audio/mp4');
      final bytes = await _read(r.stream);
      expect(bytes.length, 2399900);
      expect(bytes, data.sublist(100, 2400000));
      expect(seen.map((s) => s.headers['Range']), [
        'bytes=100-1048675',
        'bytes=1048676-2097251',
        'bytes=2097252-2399999',
      ]);
      expect(seen.map((s) => s.url.queryParameters['rn']), ['0', '1', '2']);
    });

    test('the whole file when no range is asked', () async {
      final data = _data(5000);
      final source = YouTubeStreamSource(
        _audio(length: 5000),
        _youtube(data, []),
      );
      final r = await source.request();
      expect(r.contentLength, 5000);
      expect(await _read(r.stream), data);
    });

    test('learns the size from YouTube when it was not given', () async {
      final data = _data(3000);
      final seen = <http.Request>[];
      final source = YouTubeStreamSource(
        _audio(length: -1),
        _youtube(data, seen),
      );
      final r = await source.request(0, null);
      expect(r.sourceLength, 3000);
      expect(await _read(r.stream), data);
      expect(seen.first.headers['Range'], 'bytes=0-0');
    });

    test(
      'a whole-file answer to a ranged request is cut to the range',
      () async {
        final data = _data(4000);
        final client = MockClient((_) async => http.Response.bytes(data, 200));
        final source = YouTubeStreamSource(_audio(length: 4000), client);
        final r = await source.request(1000, 1500);
        expect(await _read(r.stream), data.sublist(1000, 1500));
      },
    );

    test('an error answer fails the stream', () async {
      final client = MockClient((_) async => http.Response('no', 403));
      final source = YouTubeStreamSource(_audio(length: 4000), client);
      final r = await source.request(0, 100);
      expect(_read(r.stream), throwsA(anything));
    });
  });

  group('decodeDownloaded', () {
    test('reads the stored map', () {
      expect(
        decodeDownloaded(
          '{"Song-Artist":"/Music/Song.m4a","Bad":3,"Empty":""}',
        ),
        {'Song-Artist': '/Music/Song.m4a'},
      );
    });

    test('nothing or junk is empty', () {
      for (final bad in [null, '', 'not json', '[]', '"x"']) {
        expect(decodeDownloaded(bad), isEmpty, reason: '$bad');
      }
    });
  });
}
