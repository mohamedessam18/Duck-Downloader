import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Fan-out for the `duck_downloader/media` platform channel.
///
/// A [MethodChannel] holds exactly one handler, so the last
/// `setMethodCallHandler` call silently replaces whatever was there before.
/// The controller and the video player both need calls from this channel, and
/// they were quietly cancelling each other: opening a video killed the
/// quick-share download listener, and closing it called
/// `setMethodCallHandler(null)`, leaving *nothing* listening for the rest of
/// the session.
///
/// Registering here instead lets every listener see every call.
class DuckMediaChannel {
  DuckMediaChannel._() {
    _channel.setMethodCallHandler(_dispatch);
  }

  static final DuckMediaChannel instance = DuckMediaChannel._();

  static const channelName = 'duck_downloader/media';

  final MethodChannel _channel = const MethodChannel(channelName);
  final List<Future<void> Function(MethodCall call)> _handlers = [];

  void addHandler(Future<void> Function(MethodCall call) handler) {
    if (_handlers.contains(handler)) return;
    _handlers.add(handler);
  }

  void removeHandler(Future<void> Function(MethodCall call) handler) {
    _handlers.remove(handler);
  }

  Future<void> _dispatch(MethodCall call) async {
    // Iterate a copy: a handler may remove itself while reacting to a call.
    for (final handler in List.of(_handlers)) {
      try {
        await handler(call);
      } catch (error, stack) {
        // One misbehaving listener must not stop the others from seeing the
        // call — losing a `screenOff` here would strand a playing video.
        debugPrint('DuckMediaChannel handler failed for ${call.method}: '
            '$error\n$stack');
      }
    }
  }
}
