import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// Writes the title, artist and cover picture into a downloaded MP3's ID3v2
/// tag, so the Library, other music apps and the lock screen show them.
///
/// Frames that aren't replaced (album, year, genre, ...) are kept as they
/// are. Files that aren't MP3, or whose tag uses features this doesn't
/// handle (unsynchronisation, an extended header, ID3v2.2), are left alone.
class Id3Tagger {
  const Id3Tagger._();

  /// Room left after the frames, so a later edit needn't rewrite the file.
  static const int _padding = 1024;

  /// Rewrites [file]'s tag. Returns whether the file was changed. On any
  /// failure the original file is left untouched.
  static Future<bool> write(
    File file, {
    String? title,
    String? artist,
    Uint8List? cover,
  }) async {
    final coverMime = cover == null ? null : imageMime(cover);
    final hasTitle = title != null && title.trim().isNotEmpty;
    final hasArtist = artist != null && artist.trim().isNotEmpty;
    if (!hasTitle && !hasArtist && coverMime == null) return false;

    final raf = await file.open();
    final Uint8List head;
    final int audioStart;
    final int version;
    final List<Uint8List> kept = [];
    try {
      head = await raf.read(10);
      if (head.length < 10) return false;
      if (head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33) {
        version = head[3];
        // 0x80 unsynchronisation, 0x40 extended header, 0x10 footer.
        if ((version != 3 && version != 4) || head[5] & 0xD0 != 0) {
          return false;
        }
        final size = _syncsafe(head, 6);
        audioStart = 10 + size;
        final body = await raf.read(size);
        if (body.length < size) return false;
        final dropped = {
          if (hasTitle) 'TIT2',
          if (hasArtist) 'TPE1',
          if (coverMime != null) 'APIC',
        };
        var i = 0;
        while (i + 10 <= body.length && body[i] != 0) {
          final id = latin1.decode(body.sublist(i, i + 4));
          final frameSize = version == 4
              ? _syncsafe(body, i + 4)
              : ByteData.sublistView(body, i + 4, i + 8).getUint32(0);
          final end = i + 10 + frameSize;
          if (end > body.length) return false; // damaged tag
          if (!dropped.contains(id)) kept.add(body.sublist(i, end));
          i = end;
        }
      } else if (head[0] == 0xFF && head[1] & 0xE0 == 0xE0) {
        version = 3; // untagged MPEG audio
        audioStart = 0;
      } else {
        return false; // not an MP3
      }
    } finally {
      await raf.close();
    }

    final frames = BytesBuilder(copy: false);
    if (hasTitle) frames.add(_frame('TIT2', _text(title.trim()), version));
    if (hasArtist) frames.add(_frame('TPE1', _text(artist.trim()), version));
    kept.forEach(frames.add);
    if (coverMime != null) {
      frames.add(_frame('APIC', _picture(cover!, coverMime), version));
    }
    final tagSize = frames.length + _padding;

    final tmp = File('${file.path}.noirtag');
    try {
      final sink = tmp.openWrite();
      sink.add([0x49, 0x44, 0x33, version, 0, 0, ..._toSyncsafe(tagSize)]);
      sink.add(frames.takeBytes());
      sink.add(Uint8List(_padding));
      await sink.addStream(file.openRead(audioStart));
      await sink.close();
      await tmp.rename(file.path);
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('Could not tag ${file.path}: $e');
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      return false;
    }
  }

  /// `image/jpeg` or `image/png` from the picture's first bytes, else null.
  static String? imageMime(Uint8List bytes) {
    if (bytes.length > 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length > 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    return null;
  }

  static int _syncsafe(List<int> b, int at) =>
      (b[at] & 0x7F) << 21 |
      (b[at + 1] & 0x7F) << 14 |
      (b[at + 2] & 0x7F) << 7 |
      (b[at + 3] & 0x7F);

  static List<int> _toSyncsafe(int n) => [
    (n >> 21) & 0x7F,
    (n >> 14) & 0x7F,
    (n >> 7) & 0x7F,
    n & 0x7F,
  ];

  static Uint8List _frame(String id, Uint8List data, int version) {
    final size = data.length;
    final sizeBytes = version == 4
        ? _toSyncsafe(size)
        : [(size >> 24) & 0xFF, (size >> 16) & 0xFF, (size >> 8) & 0xFF, size & 0xFF];
    return Uint8List.fromList([...latin1.encode(id), ...sizeBytes, 0, 0, ...data]);
  }

  /// UTF-16 with a byte-order mark: valid in ID3v2.3 and v2.4, any script.
  static Uint8List _text(String s) {
    final out = BytesBuilder()..add([0x01, 0xFF, 0xFE]);
    for (final unit in s.codeUnits) {
      out.add([unit & 0xFF, unit >> 8]);
    }
    return out.takeBytes();
  }

  /// Front-cover picture, no description.
  static Uint8List _picture(Uint8List image, String mime) =>
      (BytesBuilder(copy: false)
            ..add([0x00, ...latin1.encode(mime), 0x00, 0x03, 0x00])
            ..add(image))
          .takeBytes();
}
