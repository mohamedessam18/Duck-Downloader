import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'screens/duck_app_screen.dart';
import 'services/api_client.dart';
import 'services/clipboard_service.dart';
import 'services/download_store.dart';
import 'services/file_service.dart';
import 'services/license_store.dart';
import 'state/downloads_controller.dart';

class DuckDownloaderApp extends StatefulWidget {
  const DuckDownloaderApp({super.key});

  @override
  State<DuckDownloaderApp> createState() => _DuckDownloaderAppState();
}

class _DuckDownloaderAppState extends State<DuckDownloaderApp> {
  late final DuckDownloadsController controller;

  @override
  void initState() {
    super.initState();
    controller = DuckDownloadsController(
      api: DuckApiClient(),
      clipboard: DuckClipboardService(),
      files: DuckFileService(),
      store: DownloadStore(Hive.box('duck-downloads')),
      licenseStore: LicenseStore(Hive.box('duck-downloads')),
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Duck Downloader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        fontFamily: 'Inter',
        scaffoldBackgroundColor: const Color(0xFF101112),
      ),
      home: DuckAppScreen(controller: controller),
    );
  }
}
