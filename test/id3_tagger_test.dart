import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir_player/core/services/id3_tagger.dart';

/// A fake MPEG audio frame: what follows the tag must survive untouched.
final _audio = Uint8List.fromList([0xFF, 0xFB, 0x90, 0x64, ...List.filled(500, 7)]);
final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(64, 1)]);
final _png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 9, 9]);

int _syncsafe(List<int> b, int at) =>
    (b[at] << 21) | (b[at + 1] << 14) | (b[at + 2] << 7) | b[at + 3];

List<int> _toSyncsafe(int n) =>
    [(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F];

/// Builds an ID3v2 tag the way converters do.
Uint8List _tag(int version, Map<String, List<int>> frames, {int flags = 0}) {
  final body = <int>[];
  frames.forEach((id, data) {
    final n = data.length;
    body
      ..addAll(latin1.encode(id))
      ..addAll(version == 4
          ? _toSyncsafe(n)
          : [(n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF])
      ..addAll([0, 0])
      ..addAll(data);
  });
  body.addAll(List.filled(20, 0)); // padding
  return Uint8List.fromList(
      [0x49, 0x44, 0x33, version, 0, flags, ..._toSyncsafe(body.length), ...body]);
}

List<int> _latinText(String s) => [0, ...latin1.encode(s)];

/// Frames of [bytes]' tag, and where the audio starts.
({Map<String, Uint8List> frames, int audioStart, int version}) _read(Uint8List bytes) {
  expect(latin1.decode(bytes.sublist(0, 3)), 'ID3');
  final version = bytes[3];
  final size = _syncsafe(bytes, 6);
  final frames = <String, Uint8List>{};
  var i = 10;
  while (i + 10 <= 10 + size && bytes[i] != 0) {
    final id = latin1.decode(bytes.sublist(i, i + 4));
    final n = version == 4
        ? _syncsafe(bytes, i + 4)
        : ByteData.sublistView(bytes, i + 4, i + 8).getUint32(0);
    frames[id] = bytes.sublist(i + 10, i + 10 + n);
    i += 10 + n;
  }
  return (frames: frames, audioStart: 10 + size, version: version);
}

String _utf16(Uint8List frame) {
  expect(frame.sublist(0, 3), [1, 0xFF, 0xFE]);
  final units = <int>[];
  for (var i = 3; i + 1 < frame.length; i += 2) {
    units.add(frame[i] | frame[i + 1] << 8);
  }
  return String.fromCharCodes(units);
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('noir_id3'));
  tearDown(() => dir.deleteSync(recursive: true));

  File song(List<int> bytes) => File('${dir.path}/song.mp3')..writeAsBytesSync(bytes);

  test("a converter's tag gets the real cover, title and artist", () async {
    final file = song([
      ..._tag(3, {
        'TIT2': _latinText('Clairo - Softly'),
        'TPE1': _latinText('Claire Cottrill'),
        'TALB': _latinText('Immunity'),
        'APIC': [0, ...latin1.encode('image/png'), 0, 3, 0, ..._png],
      }),
      ..._audio,
    ]);

    expect(
      await Id3Tagger.write(file, title: 'Softly', artist: 'Clairo', cover: _jpeg),
      isTrue,
    );

    final bytes = file.readAsBytesSync();
    final tag = _read(bytes);
    expect(tag.version, 3);
    expect(_utf16(tag.frames['TIT2']!), 'Softly');
    expect(_utf16(tag.frames['TPE1']!), 'Clairo');
    expect(tag.frames['TALB'], _latinText('Immunity')); // kept as it was
    final apic = tag.frames['APIC']!;
    expect(apic.sublist(0, 12), [0, ...latin1.encode('image/jpeg'), 0]);
    expect(apic[12], 3); // front cover
    expect(apic.sublist(14), _jpeg);
    expect(bytes.sublist(tag.audioStart), _audio);
    expect(File('${file.path}.noirtag').existsSync(), isFalse);
  });

  test('an untagged MP3 gets a new tag in front of the audio', () async {
    final file = song(_audio);
    expect(await Id3Tagger.write(file, title: 'Tauba Tauba', cover: _png), isTrue);
    final bytes = file.readAsBytesSync();
    final tag = _read(bytes);
    expect(_utf16(tag.frames['TIT2']!), 'Tauba Tauba');
    expect(tag.frames.containsKey('TPE1'), isFalse);
    expect(tag.frames['APIC']!.sublist(1, 10), latin1.encode('image/png'));
    expect(bytes.sublist(tag.audioStart), _audio);
  });

  test('ID3v2.4 frame sizes stay syncsafe', () async {
    final file = song([
      ..._tag(4, {'TCON': _latinText('Music'), 'TIT2': _latinText('x')}),
      ..._audio,
    ]);
    final big = Uint8List.fromList([..._jpeg, ...List.filled(300, 5)]);
    expect(await Id3Tagger.write(file, title: 'Aashiyan', cover: big), isTrue);
    final tag = _read(file.readAsBytesSync());
    expect(tag.version, 4);
    expect(tag.frames['TCON'], _latinText('Music'));
    expect(_utf16(tag.frames['TIT2']!), 'Aashiyan');
    expect(tag.frames['APIC']!.sublist(14), big);
  });

  test('non-Latin titles are written intact', () async {
    final file = song(_audio);
    await Id3Tagger.write(file, title: 'तौबा तौबा', artist: 'Björk');
    final tag = _read(file.readAsBytesSync());
    expect(_utf16(tag.frames['TIT2']!), 'तौबा तौबा');
    expect(_utf16(tag.frames['TPE1']!), 'Björk');
  });

  test('without a new cover the existing picture is kept', () async {
    final apic = [0, ...latin1.encode('image/png'), 0, 3, 0, ..._png];
    final file = song([..._tag(3, {'APIC': apic}), ..._audio]);
    await Id3Tagger.write(file, title: 'Softly', cover: Uint8List.fromList([1, 2, 3]));
    expect(_read(file.readAsBytesSync()).frames['APIC'], apic);
  });

  test('files it cannot handle safely are left alone', () async {
    final m4a = Uint8List.fromList([0, 0, 0, 0x20, ...latin1.encode('ftypM4A '), 1, 2]);
    final unsync = Uint8List.fromList([..._tag(3, {'TIT2': _latinText('a')}, flags: 0x80), ..._audio]);
    final v22 = Uint8List.fromList([..._tag(2, {}), ..._audio]);
    for (final bytes in [m4a, unsync, v22]) {
      final file = song(bytes);
      expect(await Id3Tagger.write(file, title: 'x', cover: _jpeg), isFalse);
      expect(file.readAsBytesSync(), bytes);
    }
  });

  test('a damaged tag is left alone', () async {
    final good = _tag(3, {'TIT2': _latinText('abc')});
    // Claim a frame far longer than the tag.
    good[14] = 0x7F;
    final bytes = Uint8List.fromList([...good, ..._audio]);
    final file = song(bytes);
    expect(await Id3Tagger.write(file, title: 'x'), isFalse);
    expect(file.readAsBytesSync(), bytes);
  });

  test('picture type is detected from its bytes', () {
    expect(Id3Tagger.imageMime(_jpeg), 'image/jpeg');
    expect(Id3Tagger.imageMime(_png), 'image/png');
    expect(Id3Tagger.imageMime(Uint8List.fromList(utf8.encode('<html>'))), isNull);
  });
}
