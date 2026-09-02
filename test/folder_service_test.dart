import 'dart:io';

import 'package:duck_downloader/services/folder_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePaths(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late FolderService folders;
  late String home;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('duck-folders-test');
    PathProviderPlatform.instance = _FakePaths(root.path);
    folders = const FolderService();
    home = p.join(root.path, 'Duck Downloader', 'Videos');
    await Directory(home).create(recursive: true);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<File> makeFile(String name, {String body = 'contents'}) async {
    final file = File(p.join(home, name));
    await file.writeAsString(body);
    return file;
  }

  group('naming', () {
    test('keeps a name a directory can carry', () {
      expect(FolderService.sanitiseName('Holiday 2026'), 'Holiday 2026');
      expect(FolderService.sanitiseName('  spaced  out  '), 'spaced out');
    });

    test('strips what a path cannot hold', () {
      expect(FolderService.sanitiseName('a/b'), 'a b');
      expect(FolderService.sanitiseName('why? *really*'), 'why really');
    });

    test('refuses a leading dot, which would hide the folder', () {
      // Naming a folder is not a request to make it invisible in every file
      // browser the user might open it in.
      expect(FolderService.sanitiseName('.hidden'), 'hidden');
      expect(FolderService.sanitiseName('...'), isNull);
    });

    test('a name with nothing usable in it is no name', () {
      expect(FolderService.sanitiseName(''), isNull);
      expect(FolderService.sanitiseName('   '), isNull);
      expect(FolderService.sanitiseName('///'), isNull);
    });

    test('a very long name is cut rather than refused', () {
      final long = FolderService.sanitiseName('x' * 200);
      expect(long, isNotNull);
      expect(long!.length, lessThanOrEqualTo(60));
    });

    test('Arabic names are kept as they are', () {
      expect(FolderService.sanitiseName('رحلة أسوان'), 'رحلة أسوان');
    });
  });

  group('folders', () {
    test('creating one makes a real directory', () async {
      final name = await folders.create('Trips');
      expect(name, 'Trips');
      expect(await folders.list(), ['Trips']);
    });

    test('creating the same one twice is not an error', () async {
      await folders.create('Trips');
      expect(await folders.create('Trips'), 'Trips');
      expect(await folders.list(), ['Trips']);
    });

    test('they come back in reading order', () async {
      for (final name in ['zebra', 'Apple', 'mango']) {
        await folders.create(name);
      }
      expect(await folders.list(), ['Apple', 'mango', 'zebra']);
    });

    test('renaming keeps what is inside', () async {
      await folders.create('Trips');
      final file = await makeFile('clip.mp4');
      final moved = await folders.move(
        file.path,
        folder: 'Trips',
        fallbackDir: home,
      );

      expect(await folders.rename('Trips', 'Holidays'), 'Holidays');
      expect(await folders.list(), ['Holidays']);
      expect(await File(moved!).exists(), isFalse, reason: 'the old path');
      expect(
        await File(moved.replaceFirst('/Trips/', '/Holidays/')).readAsString(),
        'contents',
      );
    });

    test('renaming onto a name in use is refused', () async {
      await folders.create('Trips');
      await folders.create('Holidays');
      expect(await folders.rename('Trips', 'Holidays'), isNull);
      expect(await folders.list(), ['Holidays', 'Trips']);
    });
  });

  group('moving files', () {
    test('a file put in a folder really moves', () async {
      await folders.create('Trips');
      final file = await makeFile('clip.mp4');

      final moved = await folders.move(
        file.path,
        folder: 'Trips',
        fallbackDir: home,
      );

      expect(moved, contains('/Trips/'));
      expect(await file.exists(), isFalse);
      expect(await File(moved!).readAsString(), 'contents');
    });

    test('and comes back out to where downloads live', () async {
      await folders.create('Trips');
      final file = await makeFile('clip.mp4');
      final inFolder = await folders.move(
        file.path,
        folder: 'Trips',
        fallbackDir: home,
      );

      final back = await folders.move(
        inFolder,
        folder: null,
        fallbackDir: home,
      );

      expect(p.dirname(back!), home);
      expect(await File(back).readAsString(), 'contents');
    });

    test('two files with the same name do not overwrite each other', () async {
      // Two downloads can share a title, and filing one away is not a reason
      // to destroy the other.
      await folders.create('Trips');
      final first = await makeFile('clip.mp4', body: 'first');
      final movedFirst = await folders.move(
        first.path,
        folder: 'Trips',
        fallbackDir: home,
      );
      final second = await makeFile('clip.mp4', body: 'second');
      final movedSecond = await folders.move(
        second.path,
        folder: 'Trips',
        fallbackDir: home,
      );

      expect(movedFirst, isNot(movedSecond));
      expect(await File(movedFirst!).readAsString(), 'first');
      expect(await File(movedSecond!).readAsString(), 'second');
    });

    test('moving a file that is already gone is not a failure', () async {
      expect(
        await folders.move('/nowhere.mp4', folder: 'Trips', fallbackDir: home),
        isNull,
      );
      expect(await folders.move(null, folder: null, fallbackDir: home), isNull);
    });

    test('moving into an unusable name does nothing', () async {
      final file = await makeFile('clip.mp4');
      expect(
        await folders.move(file.path, folder: '   ', fallbackDir: home),
        isNull,
      );
      expect(await file.exists(), isTrue, reason: 'left where it was');
    });

    test('removing a folder takes the directory, not the library', () async {
      await folders.create('Trips');
      await folders.remove('Trips');
      expect(await folders.list(), isEmpty);
    });
  });
}
