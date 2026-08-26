import 'package:duck_downloader/services/api_client.dart';
import 'package:duck_downloader/services/clipboard_service.dart';
import 'package:duck_downloader/services/download_store.dart';
import 'package:duck_downloader/services/file_service.dart';
import 'package:duck_downloader/services/media_save_service.dart';
import 'package:duck_downloader/services/premium_manager.dart';
import 'package:duck_downloader/services/purchase_repository.dart';
import 'package:duck_downloader/services/subscription_service.dart';
import 'package:duck_downloader/state/downloads_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'dart:io';

/// The back gesture is offered to registered layers innermost-first.
///
/// These cover the mechanism rather than any one screen: the bug it replaced
/// was that back could only see state the root screen held, so a player panel
/// or a folder sheet in selection mode was skipped and the whole screen came
/// down instead.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late DuckDownloadsController controller;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('duck-back');
    Hive.init(dir.path);
    final box = await Hive.openBox('duck-downloads');
    controller = DuckDownloadsController(
      api: DuckApiClient(),
      clipboard: DuckClipboardService(),
      files: DuckFileService(),
      mediaSaver: MediaSaveService(),
      store: DownloadStore(box),
      premiumManager: PremiumManager(
        subscriptions: SubscriptionService(),
        purchases: PurchaseRepository(box),
      ),
    );
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  test('nothing registered means nothing consumes back', () {
    expect(controller.hasBackInterceptors, isFalse);
    expect(controller.handleBackIntercept(), isFalse);
  });

  test('a layer that consumes back stops the chain', () {
    controller.addBackInterceptor(() => true);
    expect(controller.hasBackInterceptors, isTrue);
    expect(controller.handleBackIntercept(), isTrue);
  });

  test('the innermost layer is asked first', () {
    final asked = <String>[];
    controller.addBackInterceptor(() {
      asked.add('outer');
      return false;
    });
    controller.addBackInterceptor(() {
      asked.add('inner');
      return true;
    });

    expect(controller.handleBackIntercept(), isTrue);
    // The outer layer must never see a gesture the inner one already used.
    expect(asked, ['inner']);
  });

  test('a layer that declines passes the gesture outwards', () {
    final asked = <String>[];
    controller.addBackInterceptor(() {
      asked.add('outer');
      return true;
    });
    controller.addBackInterceptor(() {
      asked.add('inner');
      return false;
    });

    expect(controller.handleBackIntercept(), isTrue);
    expect(asked, ['inner', 'outer']);
  });

  test('a handler may unregister itself while being asked', () {
    // The real ones do exactly this: closing a layer disposes the widget that
    // registered it, mutating the list mid-iteration.
    late bool Function() self;
    self = () {
      controller.removeBackInterceptor(self);
      return true;
    };
    controller.addBackInterceptor(self);

    expect(controller.handleBackIntercept(), isTrue);
    expect(controller.hasBackInterceptors, isFalse);
  });

  test('removing a layer takes it out of the chain', () {
    bool handler() => true;
    controller.addBackInterceptor(handler);
    controller.removeBackInterceptor(handler);
    expect(controller.hasBackInterceptors, isFalse);
    expect(controller.handleBackIntercept(), isFalse);
  });
}
