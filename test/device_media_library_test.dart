import 'package:duck_downloader/models/download_models.dart';
import 'package:duck_downloader/services/device_media_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// MediaStore's MEDIA_TYPE values, spelled out because they are not in the
/// order anyone guesses: IMAGE = 1, AUDIO = 2, VIDEO = 3. The service had
/// audio and video the wrong way round and these fixtures agreed with it, so
/// the suite passed while the Videos tab listed the user's music.
const _typeImage = 1;
const _typeAudio = 2;
const _typeVideo = 3;

Map<Object?, Object?> _row({
  required int id,
  required String path,
  required int type,
  String? folderName,
  int size = 1024,
  int? durationMs,
  int modified = 1000,
}) {
  return {
    'id': id,
    'name': path.split('/').last,
    'path': path,
    'folderPath': path.substring(0, path.lastIndexOf('/')),
    'folderName': folderName,
    'size': size,
    'mimeType': 'video/mp4',
    'modified': modified,
    'type': type,
    'duration': durationMs,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeviceMediaEntry.fromNative', () {
    test('reads a full row', () {
      final entry = DeviceMediaEntry.fromNative(
        _row(
          id: 7,
          path: '/storage/emulated/0/Movies/clip.mp4',
          type: 3,
          folderName: 'Movies',
          size: 2048,
          durationMs: 90000,
          modified: 1700000000000,
        ),
      )!;

      expect(entry.name, 'clip.mp4');
      expect(entry.folderName, 'Movies');
      expect(entry.folderPath, '/storage/emulated/0/Movies');
      expect(entry.size, 2048);
      expect(entry.mediaType, 3);
      expect(entry.duration, const Duration(seconds: 90));
      expect(entry.modified.millisecondsSinceEpoch, 1700000000000);
    });

    test('rejects a row with no path', () {
      expect(DeviceMediaEntry.fromNative({'id': 1}), isNull);
    });

    test('falls back to the parent directory when the bucket is missing', () {
      // BUCKET_DISPLAY_NAME does not exist before Android 10, so the native
      // side sends null and the folder name has to come from the path.
      final entry = DeviceMediaEntry.fromNative(
        _row(id: 1, path: '/storage/emulated/0/DCIM/a.jpg', type: 1),
      )!;
      expect(entry.folderName, 'DCIM');
    });

    test('treats a zero duration as absent', () {
      // MediaStore reports 0 for images and for video it failed to probe;
      // showing "0:00" next to a photo would be nonsense.
      final entry = DeviceMediaEntry.fromNative(
        _row(id: 1, path: '/x/y/a.jpg', type: 1, durationMs: 0),
      )!;
      expect(entry.duration, isNull);
    });

    test('survives a row with missing numeric fields', () {
      final entry = DeviceMediaEntry.fromNative({
        'path': '/x/y/a.mp4',
        'name': 'a.mp4',
      })!;
      expect(entry.size, 0);
      expect(entry.mediaType, 0);
      expect(entry.duration, isNull);
    });
  });

  group('readableSize', () {
    ({int bytes, String expected}) c(int bytes, String expected) =>
        (bytes: bytes, expected: expected);

    for (final testCase in [
      c(0, ''),
      c(512, '512 B'),
      c(2048, '2.0 KB'),
      c(15 * 1024, '15 KB'),
      c(5 * 1024 * 1024, '5.0 MB'),
      c(3 * 1024 * 1024 * 1024, '3.0 GB'),
    ]) {
      test('${testCase.bytes} bytes reads as "${testCase.expected}"', () {
        final entry = DeviceMediaEntry.fromNative(
          _row(id: 1, path: '/a/b.mp4', type: 3, size: testCase.bytes),
        )!;
        expect(entry.readableSize, testCase.expected);
      });
    }
  });

  group('foldersFor', () {
    late DeviceMediaService service;
    late List<Map<Object?, Object?>> rows;
    late int queryCount;

    setUp(() {
      queryCount = 0;
      rows = [
        _row(id: 1, path: '/s/Movies/a.mp4', type: 3, modified: 300),
        _row(id: 2, path: '/s/Movies/b.mp4', type: 3, modified: 200),
        _row(id: 3, path: '/s/DCIM/c.jpg', type: 1, modified: 100),
        _row(id: 4, path: '/s/Music/d.mp3', type: 2, modified: 50),
        _row(id: 5, path: '/s/Music/e.mp3', type: 2, modified: 40),
        _row(id: 6, path: '/s/Music/f.mp3', type: 2, modified: 30),
      ];

      const channel = MethodChannel('duck_downloader/media');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'queryDeviceMedia') {
          queryCount++;
          return rows;
        }
        return null;
      });
      service = DeviceMediaService(channel: channel, hasMediaStore: true);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('duck_downloader/media'),
        null,
      );
    });

    test('splits one query into per-type folder lists', () async {
      final videos = await service.foldersFor(DownloadType.video);
      expect(videos, hasLength(1));
      expect(videos.single.name, 'Movies');
      expect(videos.single.itemCount, 2);
      expect(videos.single.totalBytes, 2048);

      final audio = await service.foldersFor(DownloadType.audio);
      expect(audio.single.itemCount, 3);
    });

    test('reuses the cached library across all three types', () async {
      // The whole point of the rewrite: one read, not one per media type.
      await service.foldersFor(DownloadType.video);
      await service.foldersFor(DownloadType.image);
      await service.foldersFor(DownloadType.audio);
      expect(queryCount, 1);
    });

    test('invalidate forces a fresh read', () async {
      await service.foldersFor(DownloadType.video);
      service.invalidate();
      await service.foldersFor(DownloadType.video);
      expect(queryCount, 2);
    });

    test('sorts folders by how much they hold', () async {
      final all = await service.destinationFolders();
      expect(all.map((folder) => folder.name), ['DCIM', 'Movies', 'Music']);
    });

    test('the cover is the newest file, not an arbitrary one', () async {
      final videos = await service.foldersFor(DownloadType.video);
      expect(videos.single.coverPath, '/s/Movies/a.mp4');
    });

    test('an empty library yields no folders rather than throwing', () async {
      rows = [];
      service.invalidate();
      expect(await service.foldersFor(DownloadType.video), isEmpty);
    });

    test('each tab gets its own media type and no other', () async {
      // The regression this suite missed for months. MEDIA_TYPE_AUDIO is 2 and
      // MEDIA_TYPE_VIDEO is 3; the service had them the other way round, so
      // asking for video folders returned the audio ones. Assert on the actual
      // files, because the folder counts alone looked plausible either way.
      final videos = await service.foldersFor(DownloadType.video);
      expect(
        videos.expand((folder) => folder.entries).map((entry) => entry.name),
        ['a.mp4', 'b.mp4'],
      );

      final audio = await service.foldersFor(DownloadType.audio);
      expect(
        audio.expand((folder) => folder.entries).map((entry) => entry.name),
        ['d.mp3', 'e.mp3', 'f.mp3'],
      );

      final images = await service.foldersFor(DownloadType.image);
      expect(
        images.expand((folder) => folder.entries).map((entry) => entry.name),
        ['c.jpg'],
      );
    });

    test('a mixed folder shows up under every tab, holding only its own half',
        () async {
      // A camera folder with clips in it, or a Downloads folder with all
      // three. It has to be reachable from each tab — and each tab must list
      // that folder's files of its own type, never the whole folder.
      rows = [
        _row(id: 1, path: '/s/Download/clip.mp4', type: _typeVideo),
        _row(id: 2, path: '/s/Download/shot.jpg', type: _typeImage),
        _row(id: 3, path: '/s/Download/song.mp3', type: _typeAudio),
      ];
      service.invalidate();

      for (final probe in [
        (type: DownloadType.video, file: 'clip.mp4'),
        (type: DownloadType.image, file: 'shot.jpg'),
        (type: DownloadType.audio, file: 'song.mp3'),
      ]) {
        final folders = await service.foldersFor(probe.type, force: true);
        expect(folders, hasLength(1), reason: '${probe.type} folder count');
        expect(folders.single.name, 'Download');
        expect(folders.single.itemCount, 1, reason: '${probe.type} count');
        expect(
          folders.single.entries.single.name,
          probe.file,
          reason: '${probe.type} contents',
        );
      }
    });

    test('a folder listing carries the type it was built for', () async {
      // refreshFolder needs it: a path alone cannot say which half of a mixed
      // folder the sheet is showing.
      final videos = await service.foldersFor(DownloadType.video);
      expect(videos.single.type, DownloadType.video);
      // The move-destination picker is deliberately type-agnostic.
      expect(await service.destinationFolders(), everyElement(
        isA<DeviceMediaFolder>().having((f) => f.type, 'type', isNull),
      ));
    });

    test('refreshFolder re-reads one folder from the library', () async {
      await service.foldersFor(DownloadType.video);
      // Stand in for a rename that happened outside the app.
      rows = [
        _row(id: 1, path: '/s/Movies/renamed.mp4', type: _typeVideo),
        _row(id: 3, path: '/s/DCIM/c.jpg', type: _typeImage),
      ];

      final folder = await service.refreshFolder('/s/Movies', DownloadType.video);
      expect(folder, isNotNull);
      expect(folder!.entries.single.name, 'renamed.mp4');
      expect(folder.itemCount, 1);
    });

    test('refreshFolder returns null once the folder holds none of that type',
        () async {
      // Moving the last video out of a folder full of photos lands here. It is
      // an ordinary outcome, so the sheet must get null rather than an error.
      rows = [_row(id: 3, path: '/s/Movies/left.jpg', type: _typeImage)];
      service.invalidate();
      expect(
        await service.refreshFolder('/s/Movies', DownloadType.video),
        isNull,
      );
    });
  });
}
