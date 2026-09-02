import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:flutter_localizations/flutter_localizations.dart';
import 'l10n/app_localizations.dart';

import 'core/app_navigator.dart';
import 'theme/duck_theme.dart';
import 'screens/onboarding_screen.dart';
import 'screens/splash_screen.dart';
import 'services/api_client.dart';
import 'services/platform_sessions.dart';
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
      // The client asks for the caller's own cookies per request. They are
      // never uploaded to be kept: the server used to hold one cookies.txt
      // that every download read, which on a shared backend made one user's
      // session everybody's.
      api: DuckApiClient(
        cookiesForUrl: const PlatformSessionStore().cookiesForUrl,
      ),
      clipboard: DuckClipboardService(),
      files: DuckFileService(),
      mediaSaver: MediaSaveService(),
      store: _store,
      premiumManager: premiumManager,
    );
  }

  /// The player's layer, created once and never replaced.
  ///
  /// An OverlayEntry rebuilt on every frame is a subtree torn down and rebuilt
  /// on every frame, and the player holds a video decoder.
  late final OverlayEntry _mediaOverlay = OverlayEntry(
    builder: (_) => ListenableBuilder(
      listenable: controller,
      builder: (_, _) => MediaOverlayRouter(controller: controller),
    ),
  );

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
        return Stack(
          children: [
            if (child != null) child,
            // Always mounted, and built once.
            //
            // This used to be created inside an AnimatedBuilder and added to
            // the Stack only while something was playing, with a fresh
            // OverlayEntry each time. Two consequences. Closing the player
            // tore the whole Overlay down while widgets inside it still
            // depended on inherited state from it, which is the
            // `_dependents.isEmpty` assertion and the red screen. And the
            // AnimatedBuilder rebuilt the entire app on every
            // notifyListeners — several times a second while a video plays.
            //
            // MediaOverlayRouter already returns an empty box when nothing is
            // open, so it can decide for itself and listen for itself.
            Material(
              type: MaterialType.transparency,
              child: Overlay(initialEntries: [_mediaOverlay]),
            ),
          ],
        );
      },
    );
  }
}
