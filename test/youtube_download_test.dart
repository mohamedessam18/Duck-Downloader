import 'dart:async';
import 'dart:io';

import 'package:duck_downloader/services/stream_quality.dart';
import 'package:duck_downloader/services/youtube_explode_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// One YouTube resolution, as far as the picker is concerned.
class _Stream {
  const _Stream(this.height);
  final int height;
}

int _heightOf(_Stream s) => s.height;

void main() {
  group('reading the video id out of a link', () {
    const id = 'dQw4w9WgXcQ';

    test('every shape the share button produces', () {
      // The library strips the query string for youtu.be and /watch but not
      // for /shorts/, so `/shorts/<id>?feature=share` parsed as
      // `<id>?feature=share` and came back null — and that is exactly what
      // YouTube's own share button hands over for a Short.
      for (final url in [
        'https://www.youtube.com/shorts/$id?feature=share',
        'https://youtube.com/shorts/$id?feature=share',
        'https://www.youtube.com/shorts/$id?si=AbCdEf',
        'https://m.youtube.com/shorts/$id?feature=shared',
        'https://www.youtube.com/shorts/$id',
        'https://www.youtube.com/live/$id?si=x',
        'https://www.youtube.com/embed/$id?start=10',
        'https://youtu.be/$id?si=x',
        'https://www.youtube.com/watch?v=$id&feature=share',
        'https://www.youtube.com/watch?v=$id',
      ]) {
        expect(YouTubeExplodeService.videoIdOf(url), id, reason: url);
      }
    });

    test('a link with no video in it is still null', () {
      expect(
        YouTubeExplodeService.videoIdOf('https://www.youtube.com/@someone'),
        isNull,
      );
      expect(
        YouTubeExplodeService.videoIdOf('https://www.youtube.com/shorts/'),
        isNull,
      );
      expect(YouTubeExplodeService.videoIdOf('not a url at all'), isNull);
      expect(YouTubeExplodeService.videoIdOf(''), isNull);
    });
  });

  group('quality selection', () {
    // The real ladder from a 4K upload, in the order the library returns it:
    // best first. That ordering is what the old code got wrong.
    const ladder = [
      _Stream(2160), _Stream(2160), _Stream(1440), _Stream(1440),
      _Stream(1080), _Stream(1080), _Stream(1080), _Stream(720),
      _Stream(720), _Stream(720), _Stream(480), _Stream(360),
      _Stream(240), _Stream(144),
    ];

    test('picks the resolution that was asked for', () {
      // Each of these downloaded 144p before, because the selection was
      // `sorted.last` on a list sorted best-first.
      expect(bestAtOrBelow(ladder, _heightOf, ceiling: 1080)?.height, 1080);
      expect(bestAtOrBelow(ladder, _heightOf, ceiling: 720)?.height, 720);
      expect(bestAtOrBelow(ladder, _heightOf, ceiling: 360)?.height, 360);
      expect(bestAtOrBelow(ladder, _heightOf, ceiling: 2160)?.height, 2160);
    });

    test('with no ceiling it takes the best, not the worst', () {
      expect(bestAtOrBelow(ladder, _heightOf)?.height, 2160);
    });

    test('an unavailable resolution rounds down, never up', () {
      // 900p is not on offer; 720p is the honest answer.
      expect(bestAtOrBelow(ladder, _heightOf, ceiling: 900)?.height, 720);
      expect(bestAtOrBelow(ladder, _heightOf, ceiling: 1439)?.height, 1080);
    });

    test('a ceiling below everything still downloads something', () {
      // A 4K-only upload with 360p requested must not fail outright.
      const highOnly = [_Stream(2160), _Stream(1440)];
      expect(bestAtOrBelow(highOnly, _heightOf, ceiling: 360)?.height, 1440);
    });

    test('nothing on offer is nothing, not a crash', () {
      expect(bestAtOrBelow(const <_Stream>[], _heightOf, ceiling: 1080), isNull);
      expect(bestAtOrBelow(const <_Stream>[], _heightOf), isNull);
    });

    test('order of the input does not matter', () {
      const shuffled = [_Stream(360), _Stream(2160), _Stream(720), _Stream(144)];
      expect(bestAtOrBelow(shuffled, _heightOf, ceiling: 1080)?.height, 720);
      expect(bestAtOrBelow(shuffled, _heightOf)?.height, 2160);
    });
  });

  group('a stalled stream is abandoned', () {
    late HttpServer server;
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('duck-stall');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() async {
      await server.close(force: true);
      await temp.delete(recursive: true);
    });

    test('stops waiting once the bytes stop coming', () async {
      // Sends a little and then goes quiet forever, which is what YouTube
      // does to a stream it has decided to throttle. The previous
      // implementation built a timer for exactly this and then awaited the
      // download before ever awaiting the timer, so it waited out Dio's
      // 15-minute receive timeout instead and reported a network failure.
      server.listen((request) async {
        request.response.headers.contentLength = 10 * 1024 * 1024;
        request.response.add(List<int>.filled(1024, 0));
        await request.response.flush();
        // Never completed on purpose.
      });

      final service = YouTubeExplodeService();
      addTearDown(service.dispose);
      final started = DateTime.now();

      await expectLater(
        service.downloadStreamWithStallTimeout(
          streamUrl: 'http://${server.address.host}:${server.port}/stream',
          savePath: '${temp.path}/out.bin',
          timeoutSeconds: 1,
        ),
        throwsA(isA<TimeoutException>()),
      );

      expect(
        DateTime.now().difference(started).inSeconds,
        lessThan(10),
        reason: 'it must give up on its own, not wait out the receive timeout',
      );
    });

    test('a stream that keeps sending is not abandoned', () async {
      server.listen((request) async {
        final body = List<int>.filled(4096, 7);
        request.response.headers.contentLength = body.length;
        request.response.add(body);
        await request.response.close();
      });

      final service = YouTubeExplodeService();
      addTearDown(service.dispose);
      final savePath = '${temp.path}/ok.bin';

      await service.downloadStreamWithStallTimeout(
        streamUrl: 'http://${server.address.host}:${server.port}/stream',
        savePath: savePath,
        timeoutSeconds: 2,
      );

      expect(await File(savePath).length(), 4096);
    });

    test('a refusal is reported as a refusal, not a stall', () async {
      server.listen((request) {
        request.response.statusCode = HttpStatus.forbidden;
        request.response.close();
      });

      final service = YouTubeExplodeService();
      addTearDown(service.dispose);

      await expectLater(
        service.downloadStreamWithStallTimeout(
          streamUrl: 'http://${server.address.host}:${server.port}/stream',
          savePath: '${temp.path}/no.bin',
          timeoutSeconds: 5,
        ),
        throwsA(isNot(isA<TimeoutException>())),
      );
    });
  });
}
