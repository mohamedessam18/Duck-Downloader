import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DuckColors {
  const DuckColors._({
    required this.gold,
    required this.warmGold,
    required this.background,
    required this.nav,
    required this.panel,
    required this.muted,
    required this.text,
    required this.textMuted,
    required this.border,
    required this.divider,
    required this.glassFill,
    required this.glassBorder,
    required this.ambientGold,
    required this.ambientAmber,
  });

  final Color gold;
  final Color warmGold;
  final Color background;
  final Color nav;
  final Color panel;
  final Color muted;
  final Color text;
  final Color textMuted;
  final Color border;
  final Color divider;
  final Color glassFill;
  final Color glassBorder;
  final Color ambientGold;
  final Color ambientAmber;

  static const danger = Color(0xFFFF7A65);
  static const green = Color(0xFF41D27D);

  static const radiusLg = 24.0;
  static const radiusPill = 999.0;

  static DuckColors of(BuildContext context) {
    return Theme.of(context).brightness == Brightness.light ? light : dark;
  }

  static const light = DuckColors._(
    gold: Color(0xFFC69214),
    warmGold: Color(0xFFB58032),
    background: Color(0xFFF5F6F8),
    nav: Color(0xFFFFFFFF),
    panel: Color(0xFFFFFFFF),
    muted: Color(0xFF6F707A),
    text: Color(0xFF151517),
    textMuted: Color(0xFF5A5A62),
    border: Color(0x14000000),
    divider: Color(0x0F000000),
    glassFill: Color(0xB8FFFFFF),
    glassBorder: Color(0x1AC69214),
    ambientGold: Color(0x30C69214),
    ambientAmber: Color(0x24B58032),
  );

  static const dark = DuckColors._(
    gold: Color(0xFFFFC52F),
    warmGold: Color(0xFFF6BD6A),
    background: Color(0xFF101112),
    nav: Color(0xFF171819),
    panel: Color(0xFF1D1D1F),
    muted: Color(0xFFB8B8B8),
    text: Color(0xFFFFFFFF),
    textMuted: Color(0xFFB8B8B8),
    border: Color(0x14FFFFFF),
    divider: Color(0x14FFFFFF),
    glassFill: Color(0x0FFFFFFF),
    glassBorder: Color(0x29FFC52F),
    ambientGold: Color(0x48FFC52F),
    ambientAmber: Color(0x32F6BD6A),
  );

  List<BoxShadow> get cardShadow => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.25),
          blurRadius: 32,
          offset: const Offset(0, 12),
          spreadRadius: -8,
        ),
        BoxShadow(
          color: gold.withValues(alpha: 0.06),
          blurRadius: 24,
          offset: const Offset(0, 4),
        ),
      ];

  List<BoxShadow> get lightCardShadow => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.03),
          blurRadius: 10,
          offset: const Offset(0, 4),
        ),
      ];
}

class DuckTheme {
  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final colors = brightness == Brightness.light
        ? DuckColors.light
        : DuckColors.dark;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: 'Inter',
      scaffoldBackgroundColor: colors.background,
      colorScheme: ColorScheme.fromSeed(
        seedColor: colors.gold,
        brightness: brightness,
        primary: colors.gold,
        surface: colors.panel,
      ),
      appBarTheme: AppBarThemeData(
        systemOverlayStyle: systemOverlayStyleFor(brightness),
      ),
      extensions: const [DuckThemeExtension()],
    );
  }

  /// System bar styling that sets icon brightness and *nothing else*.
  ///
  /// Left to itself, AppBar builds this style with `statusBarColor:
  /// backgroundColor`, and Flutter's Android embedding only calls the
  /// deprecated `Window.setStatusBarColor` / `setNavigationBarColor` /
  /// `setNavigationBarDividerColor` when the matching field is non-null. Those
  /// three setters do nothing at all on Android 15 and are what Play flags as
  /// "deprecated APIs or parameters for edge-to-edge" — under edge-to-edge the
  /// bars are transparent and our own content paints behind them, so the
  /// colours were never doing any work here anyway.
  ///
  /// Keeping every colour field null is therefore the fix and the correct
  /// behaviour at once. Only the brightness hints remain, because those decide
  /// whether the clock and gesture bar are drawn light or dark.
  static SystemUiOverlayStyle systemOverlayStyleFor(Brightness brightness) {
    final onDark = brightness == Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarIconBrightness: onDark ? Brightness.light : Brightness.dark,
      // iOS reads this one, and it is inverted relative to the Android field.
      statusBarBrightness: onDark ? Brightness.dark : Brightness.light,
      systemNavigationBarIconBrightness: onDark
          ? Brightness.light
          : Brightness.dark,
    );
  }
}

class DuckThemeExtension extends ThemeExtension<DuckThemeExtension> {
  const DuckThemeExtension();

  @override
  DuckThemeExtension copyWith() => const DuckThemeExtension();

  @override
  DuckThemeExtension lerp(DuckThemeExtension? other, double t) {
    return const DuckThemeExtension();
  }
}
