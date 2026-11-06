import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Why a Discover song's audio link couldn't be played or downloaded.
enum StreamProblem {
  /// No connection to the audio server at all: usually the network, Private
  /// DNS, an ad blocker or a VPN blocking it.
  unreachable,

  /// The server answered but refused (HTTP 401 / 403 / 429 / 451).
  refused,

  /// The file isn't there (HTTP 404 / 410), often only for a while.
  missing,

  /// The server failed (HTTP 5xx) or answered with something unexpected.
  serverError,

  /// A web page came back instead of audio: a block or captcha page.
  notAudio,

  /// The link works, so the problem is in playing it.
  none,
}

/// The outcome of [checkStream], with a message meant for the person using
/// the app and a short detail they can quote when reporting it.
class StreamCheck {
  const StreamCheck(this.problem, {required this.host, this.status});

  final StreamProblem problem;
  final String host;

  /// The HTTP status, when the server answered.
  final int? status;

  /// e.g. "eta.123tokyo.xyz, HTTP 403" or "eta.123tokyo.xyz, no connection".
  String get detail {
    final what = status != null ? 'HTTP $status' : 'no connection';
    return host.isEmpty ? what : '$host, $what';
  }

  /// What went wrong and what to try, for a snackbar. [action] is "play" or
  /// "download".
  String message(String action) {
    final text = switch (problem) {
      StreamProblem.unreachable =>
        "Couldn't reach the audio server. Your network, Private DNS, ad "
            'blocker or VPN may be blocking it. Try another network.',
      StreamProblem.refused =>
        'The audio server refused to send this song. It may be blocking your '
            'network or region. Try another network, or turn off your VPN.',
      StreamProblem.missing =>
        "This song's audio isn't available right now. Try again in a minute, "
            'or pick another song.',
      StreamProblem.serverError =>
        'The audio server is having trouble right now. Try again in a few '
            'minutes.',
      StreamProblem.notAudio =>
        'The audio server sent something other than the song (an error or a '
            'block page), often because your network or an ad blocker stepped '
            'in. Try another network.',
      StreamProblem.none => "Couldn't $action this song on this phone.",
    };
    return '$text ($detail)';
  }
}

/// Asks for the first bytes of [url] to find out why it failed. Never throws.
///
/// [request] replaces the default ranged GET, for links that must be asked
/// for in a particular way (YouTube's).
Future<StreamCheck> checkStream(
  http.Client client,
  String url, {
  Duration timeout = const Duration(seconds: 10),
  http.BaseRequest? request,
}) async {
  final uri = Uri.tryParse(url);
  final host = uri?.host ?? '';
  if (uri == null || !uri.hasScheme) {
    return StreamCheck(StreamProblem.serverError, host: host);
  }
  final http.StreamedResponse response;
  try {
    final pending = client.send(
      request ?? (http.Request('GET', uri)..headers['Range'] = 'bytes=0-1023'),
    );
    response = await pending.timeout(
      timeout,
      onTimeout: () {
        // Close a response that turns up after giving up on it.
        unawaited(
          pending.then(
            (late) => late.stream.listen(null).cancel(),
            onError: (Object _) {},
          ),
        );
        throw TimeoutException('No answer', timeout);
      },
    );
  } on TimeoutException {
    return StreamCheck(StreamProblem.unreachable, host: host);
  } on SocketException {
    return StreamCheck(StreamProblem.unreachable, host: host);
  } on HandshakeException {
    return StreamCheck(StreamProblem.unreachable, host: host);
  } on http.ClientException {
    return StreamCheck(StreamProblem.unreachable, host: host);
  } catch (_) {
    return StreamCheck(StreamProblem.unreachable, host: host);
  }
  // Only the status and headers are needed.
  unawaited(response.stream.listen((_) {}).cancel().catchError((_) {}));

  final status = response.statusCode;
  final type = (response.headers['content-type'] ?? '').toLowerCase();
  final problem = switch (status) {
    401 || 403 || 429 || 451 => StreamProblem.refused,
    404 || 410 => StreamProblem.missing,
    >= 200 && < 300 when _isAudio(type) => StreamProblem.none,
    >= 200 && < 300 => StreamProblem.notAudio,
    _ => StreamProblem.serverError,
  };
  return StreamCheck(problem, host: host, status: status);
}

/// Audio, or a type servers commonly use for any file.
bool _isAudio(String type) =>
    type.isEmpty ||
    type.startsWith('audio/') ||
    type.startsWith('video/') ||
    type.startsWith('application/octet-stream') ||
    type.startsWith('binary/octet-stream');
