import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:flutter_localizations/flutter_localizations.dart';
import 'l10n/app_localizations.dart';

import 'core/app_navigator.dart';
import 'theme/duck_theme.dart';
import 'screens/onboarding_screen.dart';
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
  late final DownloadStore _store;
  late bool _showOnboarding;

  @override
  void initState() {
    super.initState();
    _store = DownloadStore(Hive.box('duck-downloads'));
    _showOnboarding = !_store.readOnboardingCompleted();
    premiumManager = PremiumManager(
      subscriptions: SubscriptionService(),
      purchases: PurchaseRepository(Hive.box('duck-downloads')),
    );
    controller = DuckDownloadsController(
      api: DuckApiClient(),
      clipboard: DuckClipboardService(),
      files: DuckFileService(),
      mediaSaver: MediaSaveService(),
      store: _store,
      premiumManager: premiumManager,
    );
  }

  /// Leaves the intro for good.
  ///
  /// The flag is written before the rebuild so a crash between the two cannot
  /// strand the user in a loop of seeing the intro on every launch.
  Future<void> _completeOnboarding() async {
    await _store.writeOnboardingCompleted(true);
    // Premium is pitched *after* the intro rather than inside it. The main
    // screen picks this up once it is actually on screen, so the sheet does
    // not land on top of the splash animation.
    await _store.writePendingPremiumOffer(true);
    if (!mounted) return;
    setState(() => _showOnboarding = false);
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
      home: _showOnboarding
          ? OnboardingScreen(onFinished: _completeOnboarding)
          : SplashScreen(controller: controller),
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
