import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'theme/duck_theme.dart';
import 'screens/splash_screen.dart';
import 'services/api_client.dart';
import 'services/clipboard_service.dart';
import 'services/download_store.dart';
import 'services/file_service.dart';
import 'services/premium_manager.dart';
import 'services/purchase_repository.dart';
import 'services/subscription_service.dart';
import 'services/media_save_service.dart';
import 'state/downloads_controller.dart';

class DuckDownloaderApp extends StatefulWidget {
  const DuckDownloaderApp({super.key});

  @override
  State<DuckDownloaderApp> createState() => _DuckDownloaderAppState();
}

class _DuckDownloaderAppState extends State<DuckDownloaderApp> {
  late final PremiumManager premiumManager;
  late final DuckDownloadsController controller;

  @override
  void initState() {
    super.initState();
    premiumManager = PremiumManager(
      subscriptions: SubscriptionService(),
      purchases: PurchaseRepository(Hive.box('duck-downloads')),
    );
    controller = DuckDownloadsController(
      api: DuckApiClient(),
      clipboard: DuckClipboardService(),
      files: DuckFileService(),
      mediaSaver: MediaSaveService(),
      store: DownloadStore(Hive.box('duck-downloads')),
      premiumManager: premiumManager,
    );
  }

  @override
  void dispose() {
    controller.dispose();
    premiumManager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Duck Downloader',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: DuckTheme.light,
      darkTheme: DuckTheme.dark,
      home: SplashScreen(controller: controller),
    );
  }
}
