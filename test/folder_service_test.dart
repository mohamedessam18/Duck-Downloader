import 'package:duck_downloader/services/folder_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
}
