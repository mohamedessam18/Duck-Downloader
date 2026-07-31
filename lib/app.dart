import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:flutter_localizations/flutter_localizations.dart';
import 'l10n/app_localizations.dart';

import 'core/app_navigator.dart';
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
import 'widgets/media/media_overlay_router.dart';

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
      navigatorKey: appNavigatorKey,
      title: 'Duck Downloader',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: DuckTheme.light,
      darkTheme: DuckTheme.dark,
      supportedLocales: const [
        Locale('en'),
        Locale('ar'),
      ],
      localeResolutionCallback: (deviceLocale, supportedLocales) {
        if (deviceLocale != null && deviceLocale.languageCode.startsWith('ar')) {
          return const Locale('ar');
        }
        return const Locale('en');
      },
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: SplashScreen(controller: controller),
      builder: (context, child) {
        return AnimatedBuilder(
          animation: controller,
          builder: (context, child) {
            return Stack(
              children: [
                if (child != null) child,
                if (controller.playerItem != null)
                  Material(
                    type: MaterialType.transparency,
                    child: Overlay(
                      initialEntries: [
                        OverlayEntry(
                          builder: (_) => MediaOverlayRouter(controller: controller),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
          child: child,
        );
      },
    );
  }
}
