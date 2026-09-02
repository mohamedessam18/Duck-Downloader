import 'dart:io';

import 'package:duck_downloader/services/trash_service.dart';
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
  late TrashService trash;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('duck-trash-test');
    PathProviderPlatform.instance = _FakePaths(root.path);
    trash = const TrashService();
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<File> makeFile(String name, {String body = 'contents'}) async {
    final file = File(p.join(root.path, name));
    await file.parent.create(recursive: true);
    await file.writeAsString(body);
    return file;
  }

  // A local function: `main` is a body, and a getter cannot live in one.
  Directory trashFolder() =>
      Directory(p.join(root.path, 'Duck Downloader', '.duck-trash'));

  test('deleting moves the file rather than destroying it', () async {
    final file = await makeFile('clip.mp4');

    final moved = await trash.moveIn(file.path, id: 'row-1');

    expect(moved, isNotNull);
    expect(await file.exists(), isFalse, reason: 'gone from where it was');
    expect(await File(moved!).exists(), isTrue, reason: 'but still on disk');
    expect(await File(moved).readAsString(), 'contents');
  });

  test('the trash is hidden from the gallery', () async {
    // Android's media scanner skips a directory holding this file. Without it
    // a "deleted" download still shows up in the phone's photo app, which is
    // not deleted in any sense the user means.
    await trash.moveIn((await makeFile('clip.mp4')).path, id: 'row-1');
    expect(await File(p.join(trashFolder().path, '.nomedia')).exists(), isTrue);
  });

  test('two files with the same name do not collide in there', () async {
    final a = await makeFile('a/song.mp3', body: 'first');
    final b = await makeFile('b/song.mp3', body: 'second');

    final movedA = await trash.moveIn(a.path, id: 'row-a');
    final movedB = await trash.moveIn(b.path, id: 'row-b');

    expect(movedA, isNot(movedB));
    expect(await File(movedA!).readAsString(), 'first');
    expect(await File(movedB!).readAsString(), 'second');
  });

  test('restoring puts it back where it was', () async {
    final file = await makeFile('clip.mp4');
    final original = file.path;
    final moved = await trash.moveIn(original, id: 'row-1');

    final restored = await trash.moveOut(moved, original);

    expect(restored, original);
    expect(await File(original).readAsString(), 'contents');
    expect(await File(moved!).exists(), isFalse);
  });

  test('restoring never overwrites what is there now', () async {
    // Something else may live at the old path by now, and restoring is not a
    // reason to destroy it.
    final file = await makeFile('clip.mp4', body: 'deleted one');
    final original = file.path;
    final moved = await trash.moveIn(original, id: 'row-1');
    await makeFile('clip.mp4', body: 'a newer file');

    final restored = await trash.moveOut(moved, original);

    expect(restored, isNot(original));
    expect(await File(original).readAsString(), 'a newer file');
    expect(await File(restored!).readAsString(), 'deleted one');
  });

  test('erasing is final', () async {
    final moved = await trash.moveIn(
      (await makeFile('clip.mp4')).path,
      id: 'row-1',
    );
    await trash.erase(moved);
    expect(await File(moved!).exists(), isFalse);
  });

  test('a sweep removes what no row claims, and keeps what one does', () async {
    final kept = await trash.moveIn(
      (await makeFile('kept.mp4')).path,
      id: 'kept',
    );
    final orphan = await trash.moveIn(
      (await makeFile('orphan.mp4')).path,
      id: 'orphan',
    );

    // A restore or a purge can be interrupted — the app is killed, a write
    // fails — and without this the folder would only ever grow.
    await trash.sweepOrphans({kept!});

    expect(await File(kept).exists(), isTrue);
    expect(await File(orphan!).exists(), isFalse);
    expect(await File(p.join(trashFolder().path, '.nomedia')).exists(), isTrue);
  });

  test('deleting a file that is already gone is not a failure', () async {
    // The row still has to be removable; a record pointing at nothing is not
    // a reason to refuse.
    expect(await trash.moveIn('/nowhere/at/all.mp4', id: 'row-1'), isNull);
    expect(await trash.moveIn(null, id: 'row-1'), isNull);
    await trash.erase('/nowhere/at/all.mp4');
  });

  test('restoring something that is no longer there says so', () async {
    expect(await trash.moveOut('/gone.mp4', '/somewhere/clip.mp4'), isNull);
    expect(await trash.moveOut(null, '/somewhere/clip.mp4'), isNull);
  });

  test('a week is the window', () {
    expect(TrashService.retention, const Duration(days: 7));
  });
}
