import 'package:duck_downloader/l10n/app_localizations.dart';
import 'package:duck_downloader/screens/onboarding_screen.dart';
import 'package:duck_downloader/theme/duck_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host({required VoidCallback onFinished, Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    theme: DuckTheme.light,
    supportedLocales: const [Locale('en'), Locale('ar')],
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: OnboardingScreen(onFinished: onFinished),
  );
}

/// Pumps a bounded number of frames.
///
/// `pumpAndSettle` is unusable here: AmbientBackground animates forever, so it
/// spins until the timeout. A single large pump is not enough either — the
/// PageView transition needs several frames to reach the next page.
Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 14; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  // The permission plugin has no implementation under flutter_test, so the
  // probe in initState throws. The screen swallows that on purpose; these
  // tests would fail loudly if it ever stopped doing so.
  testWidgets('opens on the first page without a platform implementation',
      (tester) async {
    await tester.pumpWidget(_host(onFinished: () {}));
    await _settle(tester);

    expect(find.text('Everything, in one tap'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
  });

  testWidgets('Skip finishes immediately from the first page', (tester) async {
    var finished = 0;
    await tester.pumpWidget(_host(onFinished: () => finished++));
    await _settle(tester);

    await tester.tap(find.text('Skip'));
    await tester.pump();

    expect(finished, 1);
  });

  testWidgets('walks all three pages and only then offers to start',
      (tester) async {
    var finished = 0;
    await tester.pumpWidget(_host(onFinished: () => finished++));
    await _settle(tester);

    await tester.tap(find.text('Next'));
    await _settle(tester);
    expect(find.text('A vault only you can open'), findsOneWidget);

    await tester.tap(find.text('Next'));
    await _settle(tester);
    expect(find.text('Two things Duck needs'), findsOneWidget);

    // Last page: Skip is gone and the button becomes the finish action.
    expect(find.text('Get Started'), findsOneWidget);
    expect(finished, 0);

    await tester.tap(find.text('Get Started'));
    await tester.pump();
    expect(finished, 1);
  });

  testWidgets('renders in Arabic', (tester) async {
    await tester.pumpWidget(
      _host(onFinished: () {}, locale: const Locale('ar')),
    );
    await _settle(tester);

    expect(find.text('كل حاجة بضغطة واحدة'), findsOneWidget);
    expect(find.text('تخطي'), findsOneWidget);
  });
}
