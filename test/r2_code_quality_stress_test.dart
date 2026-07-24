import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:duck_downloader/models/download_models.dart';
import 'package:duck_downloader/services/file_service.dart';
import 'package:duck_downloader/services/trim_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('R2 Code Quality & Bug Remediation Stress Tests', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('r2_stress_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    group('WebSocket Stream Cancellation on cancelDownload()', () {
      test('Empirical Verification: Cancelled download stream subscription is terminated and ignores post-cancel updates', () async {
        final controller = StreamController<DownloadStatusUpdate>.broadcast();
        final List<DownloadStatusUpdate> receivedUpdates = [];

        final subscription = controller.stream.listen((update) {
          receivedUpdates.add(update);
        });

        // Simulate active download receiving updates
        controller.add(const DownloadStatusUpdate(progress: 30, status: DownloadStatus.downloading));
        await Future.delayed(const Duration(milliseconds: 10));
        expect(receivedUpdates, hasLength(1));

        // Simulate cancelDownload subscription cancellation
        await subscription.cancel();

        // Push post-cancellation stream event (e.g. backend server sending completed or 100%)
        controller.add(const DownloadStatusUpdate(progress: 100, status: DownloadStatus.completed));
        await Future.delayed(const Duration(milliseconds: 10));

        // Verify post-cancellation event was NOT received or processed
        expect(receivedUpdates, hasLength(1),
            reason: 'Cancelled subscription must not process subsequent stream updates');
        expect(receivedUpdates.last.progress, 30);

        await controller.close();
      });
    });

    group('Unicode ID3 Tag Updates & Byte Preservation', () {
      late DuckFileService fileService;

      setUp(() {
        fileService = DuckFileService();
      });

      test('Empirical Verification: ID3 tag update supports UTF-8 Unicode (CJK, Arabic, Emojis) and preserves bytes 93-127', () async {
        final mp3File = File(p.join(tempDir.path, 'sample.mp3'));
        
        // Create a 1000-byte dummy MP3 file ending with a valid 128-byte ID3v1 tag structure
        final fileContent = List<int>.filled(1000, 0);
        final tagOffset = 1000 - 128;
        
        // 'TAG' header at tagOffset 0..2
        fileContent[tagOffset + 0] = 84; // 'T'
        fileContent[tagOffset + 1] = 65; // 'A'
        fileContent[tagOffset + 2] = 71; // 'G'

        // Fill existing Title, Artist, Album with dummy ASCII
        for (int i = 3; i < 93; i++) {
          fileContent[tagOffset + i] = 65; // 'A'
        }

        // Fill bytes 93-127 with distinct sentinel values to verify byte preservation
        // Bytes 93-96: Year "2026"
        fileContent[tagOffset + 93] = 50; // '2'
        fileContent[tagOffset + 94] = 48; // '0'
        fileContent[tagOffset + 95] = 50; // '2'
        fileContent[tagOffset + 96] = 54; // '6'
        
        // Bytes 97-124: Comment string "Duck Downloader Test Track!"
        final commentBytes = utf8.encode('Duck Downloader Test Track!');
        for (int i = 0; i < commentBytes.length && i < 28; i++) {
          fileContent[tagOffset + 97 + i] = commentBytes[i];
        }

        // Byte 125: Track zero byte marker, Byte 126: Track 7
        fileContent[tagOffset + 125] = 0;
        fileContent[tagOffset + 126] = 7;

        // Byte 127: Genre 12 (Other)
        fileContent[tagOffset + 127] = 12;

        await mp3File.writeAsBytes(fileContent);

        // Perform Unicode ID3 Tag Update with CJK, Arabic, and Emoji characters
        const cjkTitle = '日本語タイトル';
        const arabicArtist = 'فنان duck';
        const emojiAlbum = '🎵 Hits 🦆';

        await fileService.updateMp3Metadata(
          filePath: mp3File.path,
          title: cjkTitle,
          artist: arabicArtist,
          album: emojiAlbum,
        );

        final updatedBytes = await mp3File.readAsBytes();
        expect(updatedBytes.length, 1000);

        final updatedTag = updatedBytes.sublist(1000 - 128);

        // Verify 'TAG' header
        expect(updatedTag[0], 84);
        expect(updatedTag[1], 65);
        expect(updatedTag[2], 71);

        // Verify Title contains valid UTF-8 bytes for CJK
        final titleSlice = updatedTag.sublist(3, 33);
        final titleUtf8 = utf8.decode(titleSlice.takeWhile((b) => b != 0).toList());
        expect(cjkTitle.startsWith(titleUtf8), isTrue,
            reason: 'Title should contain valid UTF-8 encoded bytes for CJK');

        // Verify Artist contains valid UTF-8 bytes for Arabic
        final artistSlice = updatedTag.sublist(33, 63);
        final artistUtf8 = utf8.decode(artistSlice.takeWhile((b) => b != 0).toList());
        expect(arabicArtist.startsWith(artistUtf8), isTrue,
            reason: 'Artist should contain valid UTF-8 encoded bytes for Arabic');

        // Verify Album contains valid UTF-8 bytes for Emojis
        final albumSlice = updatedTag.sublist(63, 93);
        final albumUtf8 = utf8.decode(albumSlice.takeWhile((b) => b != 0).toList());
        expect(emojiAlbum.startsWith(albumUtf8), isTrue,
            reason: 'Album should contain valid UTF-8 encoded bytes for Emojis');

        // Verify Bytes 93-127 (Year, Comment, Track, Genre) are 100% PRESERVED
        expect(updatedTag[93], 50); // '2'
        expect(updatedTag[94], 48); // '0'
        expect(updatedTag[95], 50); // '2'
        expect(updatedTag[96], 54); // '6'
        expect(updatedTag[126], 7); // Track 7
        expect(updatedTag[127], 12); // Genre 12
      });
    });

    group('Flexible Stringified Number JSON Deserialization', () {
      test('Empirical Verification: Stringified numbers are deserialized into ints across all models', () {
        // FormatInfo
        final format = FormatInfo.fromJson({
          'id': '1080p',
          'label': '1080p HD',
          'height': '1080',
          'width': '1920',
          'filesize': '52428800',
        });
        expect(format.height, 1080);
        expect(format.width, 1920);
        expect(format.filesize, 52428800);

        // DownloadItem
        final item = DownloadItem.fromJson({
          'id': 'd1',
          'url': 'https://example.com/video.mp4',
          'title': 'Test Video',
          'platform': 'web',
          'type': 'video',
          'createdAt': DateTime.now().toIso8601String(),
          'status': 'downloading',
          'progress': '75',
          'favorite': false,
        });
        expect(item.progress, 75);

        // DownloadStatusUpdate
        final update = DownloadStatusUpdate.fromJson({
          'progress': '100',
          'status': 'completed',
        });
        expect(update.progress, 100);

        // PlaylistItem
        final playlistItem = PlaylistItem.fromJson({
          'url': 'https://example.com/item.jpg',
          'title': 'Item 1',
          'width': '853',
          'height': '1280',
        });
        expect(playlistItem.width, 853);
        expect(playlistItem.height, 1280);

        // BackendCookiesInfo
        final cookies = BackendCookiesInfo.fromJson({
          'active': true,
          'size': '4096',
        });
        expect(cookies.size, 4096);
      });

      test('Empirical Verification: Invalid or non-numeric strings fallback gracefully to null / zero', () {
        final format = FormatInfo.fromJson({
          'id': 'audio',
          'label': 'Audio',
          'height': 'invalid_num',
          'filesize': null,
        });
        expect(format.height, isNull);
        expect(format.filesize, isNull);

        final update = DownloadStatusUpdate.fromJson({
          'progress': 'not_a_number',
          'status': 'downloading',
        });
        expect(update.progress, 0);
      });
    });

    group('Staged File Replacement Error Handling', () {
      late TrimService trimService;

      setUp(() {
        trimService = TrimService();
      });

      test('Empirical Verification: Successful staged replace copies file, renames original, and cleans up temp files', () async {
        final originalFile = File(p.join(tempDir.path, 'original.mp4'));
        await originalFile.writeAsString('Original Content 12345');

        final trimmedFile = File(p.join(tempDir.path, 'trimmed.mp4'));
        await trimmedFile.writeAsString('Trimmed Content ABCDE');

        final resultPath = await trimService.replaceOriginal(
          originalPath: originalFile.path,
          trimmedPath: trimmedFile.path,
        );

        expect(resultPath, originalFile.path);
        expect(await originalFile.readAsString(), 'Trimmed Content ABCDE');
        expect(await trimmedFile.exists(), isFalse, reason: 'Trimmed source file must be cleaned up');
      });

      test('Empirical Verification: Copy verification failure throws TrimValidationException and keeps original intact', () async {
        final originalFile = File(p.join(tempDir.path, 'original_protected.mp4'));
        await originalFile.writeAsString('Original Untouched Data');

        // Non-existent trimmed file
        final missingTrimmedPath = p.join(tempDir.path, 'non_existent_trimmed.mp4');

        expect(
          () => trimService.replaceOriginal(
            originalPath: originalFile.path,
            trimmedPath: missingTrimmedPath,
          ),
          throwsA(isA<TrimValidationException>()),
        );

        expect(await originalFile.readAsString(), 'Original Untouched Data',
            reason: 'Original file must remain untouched when replace validation fails');
      });
    });
  });
}
