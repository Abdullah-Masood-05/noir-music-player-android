import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:noir_player/core/services/now_playing.dart';
import 'package:noir_player/core/services/stream_check.dart';

const _url = 'https://eta.123tokyo.xyz/get.php/2/6b/x.mp3?n=Hum';

Future<StreamCheck> _check(
  int status, {
  String type = 'audio/mpeg',
  Object? error,
}) => checkStream(
  MockClient((req) async {
    if (error != null) throw error;
    expect(req.headers['Range'], 'bytes=0-1023');
    return http.Response(
      'x',
      status,
      headers: {if (type.isNotEmpty) 'content-type': type},
    );
  }),
  _url,
);

void main() {
  group('checkStream', () {
    test(
      'no connection points at the network, DNS, ad blocker or VPN',
      () async {
        for (final error in [
          const SocketException('Failed host lookup'),
          http.ClientException('Connection reset'),
          const HandshakeException('bad certificate'),
        ]) {
          final check = await _check(200, error: error);
          expect(check.problem, StreamProblem.unreachable);
          expect(check.message('play'), contains('Private DNS'));
          expect(check.detail, 'eta.123tokyo.xyz, no connection');
        }
      },
    );

    test('a slow server counts as unreachable', () async {
      final check = await checkStream(
        MockClient(
          (_) => Future.delayed(
            const Duration(seconds: 5),
            () => http.Response('', 200),
          ),
        ),
        _url,
        timeout: const Duration(milliseconds: 50),
      );
      expect(check.problem, StreamProblem.unreachable);
    });

    test('HTTP statuses are told apart', () async {
      expect((await _check(403)).problem, StreamProblem.refused);
      expect((await _check(429)).problem, StreamProblem.refused);
      expect((await _check(451)).problem, StreamProblem.refused);
      expect((await _check(404)).problem, StreamProblem.missing);
      expect((await _check(410)).problem, StreamProblem.missing);
      expect((await _check(502)).problem, StreamProblem.serverError);
      expect((await _check(302)).problem, StreamProblem.serverError);
      expect((await _check(206)).problem, StreamProblem.none);
      expect((await _check(200)).problem, StreamProblem.none);
    });

    test('a web page or error text instead of audio is caught', () async {
      for (final type in [
        'text/html; charset=UTF-8',
        'application/json',
        'text/plain',
      ]) {
        expect(
          (await _check(200, type: type)).problem,
          StreamProblem.notAudio,
          reason: type,
        );
      }
      for (final type in ['audio/mpeg', 'application/octet-stream', '']) {
        expect(
          (await _check(206, type: type)).problem,
          StreamProblem.none,
          reason: type,
        );
      }
    });

    test('messages carry a detail to quote in a report', () async {
      final check = await _check(403);
      expect(check.detail, 'eta.123tokyo.xyz, HTTP 403');
      expect(check.message('play'), endsWith('(eta.123tokyo.xyz, HTTP 403)'));
      expect(
        (await _check(200)).message('download'),
        startsWith("Couldn't download this song"),
      );
    });

    test('a broken link never throws', () async {
      final check = await checkStream(
        MockClient((_) async => http.Response('', 200)),
        '::',
      );
      expect(check.problem, StreamProblem.serverError);
    });
  });

  group('nowPlayingUpdate', () {
    const song = MediaItem(
      id: 'discover:Hum',
      title: 'Hum',
      artist: 'Murtaza Qizilbash',
    );
    const length = Duration(minutes: 3, seconds: 12);

    test("the song's length, once loaded, is kept on later events", () {
      // Loaded: the length is added.
      final withLength = nowPlayingUpdate(
        current: song,
        item: song,
        loadedDuration: length,
      );
      expect(withLength!.duration, length);
      // The next playback event re-reports the queue copy, which has no
      // length: nothing changes, so the progress bar stays usable.
      expect(
        nowPlayingUpdate(current: withLength, item: song, loadedDuration: null),
        isNull,
      );
      expect(
        nowPlayingUpdate(
          current: withLength,
          item: song,
          loadedDuration: length,
        ),
        isNull,
      );
    });

    test('a cover found later is not dropped', () {
      final art = Uri.parse(
        'https://cdn-images.dzcdn.net/images/cover/abc/500x500.jpg',
      );
      final current = song.copyWith(artUri: art, duration: length);
      expect(
        nowPlayingUpdate(current: current, item: song, loadedDuration: length),
        isNull,
      );
    });

    test('while a new song loads, the old length is not used', () {
      const previous = MediaItem(
        id: '42',
        title: 'Old',
        duration: Duration(minutes: 5),
      );
      final update = nowPlayingUpdate(
        current: previous,
        item: song,
        loadedDuration: null,
      );
      expect(update!.id, song.id);
      expect(update.duration, isNull);
    });

    test("a new song with a known length is published as it is", () {
      const local = MediaItem(id: '7', title: 'Local', duration: length);
      final update = nowPlayingUpdate(
        current: song,
        item: local,
        loadedDuration: null,
      );
      expect(update!.duration, length);
    });

    test("the player's exact length replaces the library's estimate", () {
      const local = MediaItem(
        id: '7',
        title: 'Local',
        duration: Duration(seconds: 191),
      );
      final update = nowPlayingUpdate(
        current: local,
        item: local,
        loadedDuration: length,
      );
      expect(update!.duration, length);
    });
  });
}
