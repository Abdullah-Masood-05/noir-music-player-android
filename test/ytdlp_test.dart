import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir_player/core/services/discover_api.dart';
import 'package:noir_player/core/services/ytdlp.dart';

void main() {
  group('parseYtAudio', () {
    test("reads yt-dlp's JSON for the chosen audio", () {
      final audio = parseYtAudio(
        jsonEncode({
          'id': 'SQdgdWayPhQ',
          'title': 'Clairo - Softly',
          'duration': 185,
          'ext': 'm4a',
          'url':
              'https://rr5---sn-2uja-aixel.googlevideo.com/videoplayback?expire=1',
        }),
      );
      expect(audio.videoId, 'SQdgdWayPhQ');
      expect(audio.url, startsWith('https://rr5---'));
      expect(audio.title, 'Clairo - Softly');
      expect(audio.duration, const Duration(seconds: 185));
    });

    test('fractional and missing durations', () {
      final a = parseYtAudio(
        jsonEncode({'id': 'x', 'url': 'https://a/b', 'duration': 12.5}),
      );
      expect(a.duration, const Duration(milliseconds: 12500));
      final b = parseYtAudio(jsonEncode({'id': 'x', 'url': 'https://a/b'}));
      expect(b.duration, isNull);
    });

    test('nothing playable is a clear error', () {
      for (final bad in [
        null,
        '',
        'not json',
        '[]',
        jsonEncode({'id': 'x'}),
        jsonEncode({'id': 'x', 'url': 'http://insecure/a'}),
      ]) {
        expect(
          () => parseYtAudio(bad),
          throwsA(isA<DiscoverException>()),
          reason: '$bad',
        );
      }
    });
  });

  group('friendlyYtDlpError', () {
    test('bot checks', () {
      expect(
        friendlyYtDlpError(
          "ERROR: [youtube] abc: Sign in to confirm you're not a bot.",
        ),
        contains("isn't a bot"),
      );
    });

    test('no connection', () {
      for (final raw in [
        'ERROR: [youtube] abc: Unable to download webpage: <urlopen error [Errno 7] No address associated with hostname>',
        'ERROR: Read timed out.',
        'Temporary failure in name resolution',
      ]) {
        expect(
          friendlyYtDlpError(raw),
          startsWith("Couldn't reach YouTube"),
          reason: raw,
        );
      }
    });

    test('unavailable videos', () {
      expect(
        friendlyYtDlpError('ERROR: [youtube] abc: Video unavailable'),
        contains("isn't available"),
      );
      expect(
        friendlyYtDlpError('ERROR: [youtube] abc: Private video'),
        contains("isn't available"),
      );
    });

    test('rate limits and refusals', () {
      expect(
        friendlyYtDlpError('ERROR: HTTP Error 429: Too Many Requests'),
        contains('limiting'),
      );
      expect(
        friendlyYtDlpError(
          'ERROR: unable to download video data: HTTP Error 403: Forbidden',
        ),
        contains('refused'),
      );
    });

    test('anything else shows its first line, without the ERROR prefix', () {
      expect(
        friendlyYtDlpError('ERROR: something odd happened\nTraceback ...'),
        "Couldn't get this song from YouTube. (something odd happened)",
      );
      expect(friendlyYtDlpError(null), "Couldn't get this song from YouTube.");
      expect(friendlyYtDlpError('ERROR: ${'x' * 300}').length, lessThan(220));
    });
  });

  test('songs are searched by title and artist', () {
    expect(YtDlp.searchTarget('Softly', 'Clairo'), 'ytsearch1:Softly Clairo');
    expect(
      YtDlp.videoTarget('SQdgdWayPhQ'),
      'https://www.youtube.com/watch?v=SQdgdWayPhQ',
    );
  });
}
