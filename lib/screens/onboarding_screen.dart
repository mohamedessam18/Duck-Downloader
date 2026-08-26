import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/haptics.dart';
import '../core/permissions/permission_service.dart';
import '../l10n/app_localizations.dart';
import '../theme/duck_theme.dart';
import '../widgets/ambient_background.dart';
import '../widgets/duck_liquid_glass.dart';
import '../widgets/duck_motion.dart';

/// First-run intro: what Duck does, what the Vault is, and the two permissions
/// it needs.
///
/// Three pages, skippable. The permission page asks for real grants rather
/// than only explaining, so the app is usable the moment the intro ends — but
/// nothing here blocks: every page can be skipped, and a denied permission is
/// re-requested later at the point of use.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onFinished});

  /// Called once, when the user finishes or skips. The caller persists the
  /// flag and moves on — this screen deliberately owns no storage.
  final VoidCallback onFinished;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const _pageCount = 3;

  final PageController _pageController = PageController();
  final PermissionService _permissions = PermissionService();

  int _page = 0;
  bool _mediaGranted = false;
  bool _notificationsGranted = false;
  bool _mediaBusy = false;
  bool _notificationsBusy = false;

  @override
  void initState() {
    super.initState();
    _refreshPermissionStates();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// Reflects grants the user may already have given in a previous install.
  ///
  /// Guarded because this runs from `initState`: a platform-channel failure
  /// here would otherwise become an unhandled exception before the first frame
  /// and take the whole intro down. Falling back to "not granted" is harmless
  /// — the buttons simply stay actionable.
  Future<void> _refreshPermissionStates() async {
    bool media = false;
    bool notifications = false;
    try {
      media = await _permissions.hasMediaLibraryAccess();
      notifications = await Permission.notification.isGranted;
    } catch (error, stackTrace) {
      debugPrint('Onboarding permission probe failed: $error\n$stackTrace');
    }
    if (!mounted) return;
    setState(() {
      _mediaGranted = media;
      _notificationsGranted = notifications;
    });
  }

  void _finish() {
    DuckHaptics.success();
    widget.onFinished();
  }

  void _next() {
    if (_page >= _pageCount - 1) {
      _finish();
      return;
    }
    DuckHaptics.tap();
    _pageController.nextPage(
      duration: DuckMotion.transitionDuration,
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _requestMedia() async {
    setState(() => _mediaBusy = true);
    final granted = await _permissions.requestMediaLibraryAccess();
    if (!mounted) return;
    setState(() {
      _mediaGranted = granted;
      _mediaBusy = false;
    });
    granted ? DuckHaptics.success() : DuckHaptics.error();
  }

  Future<void> _requestNotifications() async {
    setState(() => _notificationsBusy = true);
    final granted = await _permissions.requestNotificationPermission();
    if (!mounted) return;
    setState(() {
      _notificationsGranted = granted;
      _notificationsBusy = false;
    });
    granted ? DuckHaptics.success() : DuckHaptics.error();
  }

  @override
  Widget build(BuildContext context) {
    final colors = DuckColors.of(context);
    final strings = AppLocalizations.of(context);
    final isLight = Theme.of(context).brightness == Brightness.light;

    return Scaffold(
      backgroundColor: colors.background,
      body: AmbientBackground(
        child: SafeArea(
          child: Column(
            children: [
              _TopBar(
                onSkip: _finish,
                label: strings.translate('onbSkip'),
                // Nothing left to skip past on the last page.
                visible: _page < _pageCount - 1,
                color: colors.textMuted,
              ),
              Expanded(
                child: PageView(
                  controller: _pageController,
                  onPageChanged: (index) {
                    DuckHaptics.selection();
                    setState(() => _page = index);
                  },
                  children: [
                    _FeaturesPage(colors: colors, strings: strings),
                    _VaultPage(colors: colors, strings: strings),
                    _PermissionsPage(
                      colors: colors,
                      strings: strings,
                      isLight: isLight,
                      mediaGranted: _mediaGranted,
                      notificationsGranted: _notificationsGranted,
                      mediaBusy: _mediaBusy,
                      notificationsBusy: _notificationsBusy,
                      onRequestMedia: _requestMedia,
                      onRequestNotifications: _requestNotifications,
                    ),
                  ],
                ),
              ),
              _BottomBar(
                page: _page,
                pageCount: _pageCount,
                colors: colors,
                isLight: isLight,
                label: _page == _pageCount - 1
                    ? strings.translate('onbStart')
                    : strings.translate('onbNext'),
                onNext: _next,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Chrome ──────────────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.onSkip,
    required this.label,
    required this.visible,
    required this.color,
  });

  final VoidCallback onSkip;
  final String label;
  final bool visible;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: DuckMotion.transitionDuration,
          child: IgnorePointer(
            ignoring: !visible,
            child: TextButton(
              onPressed: onSkip,
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.page,
    required this.pageCount,
    required this.colors,
    required this.isLight,
    required this.label,
    required this.onNext,
  });

  final int page;
  final int pageCount;
  final DuckColors colors;
  final bool isLight;
  final String label;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var index = 0; index < pageCount; index++)
                AnimatedContainer(
                  duration: DuckMotion.transitionDuration,
                  curve: Curves.easeOut,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  height: 6,
                  // The active dot stretches instead of just changing colour,
                  // so progress reads at a glance.
                  width: index == page ? 22 : 6,
                  decoration: BoxDecoration(
                    color: index == page
                        ? colors.gold
                        : colors.textMuted.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Pressable(
            onTap: onNext,
            child: Container(
              width: double.infinity,
              height: 54,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [colors.gold, colors.warmGold],
                ),
                borderRadius: BorderRadius.circular(DuckColors.radiusPill),
                boxShadow: [
                  BoxShadow(
                    color: colors.gold.withValues(alpha: isLight ? 0.28 : 0.34),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Text(
                label,
                style: const TextStyle(
                  color: Color(0xFF141414),
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shared page skeleton: art, headline, body, then whatever the page adds.
class _Page extends StatelessWidget {
  const _Page({
    required this.asset,
    required this.title,
    required this.body,
    required this.colors,
    this.children = const [],
  });

  final String asset;
  final String title;
  final String body;
  final DuckColors colors;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          EntranceFade(
            index: 0,
            child: SizedBox(
              height: 200,
              child: Center(
                child: Image.asset(
                  asset,
                  height: 180,
                  fit: BoxFit.contain,
                  // A missing duck must not take the whole intro down with it.
                  errorBuilder: (_, _, _) => Icon(
                    Icons.downloading,
                    size: 96,
                    color: colors.gold,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          EntranceFade(
            index: 1,
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.text,
                fontSize: 26,
                fontWeight: FontWeight.w800,
                height: 1.25,
              ),
            ),
          ),
          const SizedBox(height: 12),
          EntranceFade(
            index: 2,
            child: Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.textMuted,
                fontSize: 15,
                height: 1.6,
              ),
            ),
          ),
          const SizedBox(height: 24),
          ...children,
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// A checked bullet used on the first two pages.
class _Bullet extends StatelessWidget {
  const _Bullet({
    required this.icon,
    required this.text,
    required this.colors,
    required this.index,
  });

  final IconData icon;
  final String text;
  final DuckColors colors;
  final int index;

  @override
  Widget build(BuildContext context) {
    return EntranceFade(
      index: index,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: colors.gold.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 17, color: colors.gold),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text(
                  text,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 14.5,
                    height: 1.45,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Pages ───────────────────────────────────────────────────────────────────

class _FeaturesPage extends StatelessWidget {
  const _FeaturesPage({required this.colors, required this.strings});

  final DuckColors colors;
  final AppLocalizations strings;

  @override
  Widget build(BuildContext context) {
    return _Page(
      asset: 'assets/images/ducks/duck_idle.png',
      title: strings.translate('onbFeaturesTitle'),
      body: strings.translate('onbFeaturesBody'),
      colors: colors,
      children: [
        _Bullet(
          icon: Icons.high_quality_rounded,
          text: strings.translate('onbFeatureQuality'),
          colors: colors,
          index: 3,
        ),
        _Bullet(
          icon: Icons.content_paste_rounded,
          text: strings.translate('onbFeatureClipboard'),
          colors: colors,
          index: 4,
        ),
        _Bullet(
          icon: Icons.perm_media_rounded,
          text: strings.translate('onbFeatureLibrary'),
          colors: colors,
          index: 5,
        ),
      ],
    );
  }
}

class _VaultPage extends StatelessWidget {
  const _VaultPage({required this.colors, required this.strings});

  final DuckColors colors;
  final AppLocalizations strings;

  @override
  Widget build(BuildContext context) {
    return _Page(
      asset: 'assets/images/ducks/duck_success.png',
      title: strings.translate('onbVaultTitle'),
      body: strings.translate('onbVaultBody'),
      colors: colors,
      children: [
        _Bullet(
          icon: Icons.lock_rounded,
          text: strings.translate('onbVaultPoint1'),
          colors: colors,
          index: 3,
        ),
        _Bullet(
          icon: Icons.visibility_off_rounded,
          text: strings.translate('onbVaultPoint2'),
          colors: colors,
          index: 4,
        ),
        _Bullet(
          icon: Icons.fingerprint_rounded,
          text: strings.translate('onbVaultPoint3'),
          colors: colors,
          index: 5,
        ),
      ],
    );
  }
}

class _PermissionsPage extends StatelessWidget {
  const _PermissionsPage({
    required this.colors,
    required this.strings,
    required this.isLight,
    required this.mediaGranted,
    required this.notificationsGranted,
    required this.mediaBusy,
    required this.notificationsBusy,
    required this.onRequestMedia,
    required this.onRequestNotifications,
  });

  final DuckColors colors;
  final AppLocalizations strings;
  final bool isLight;
  final bool mediaGranted;
  final bool notificationsGranted;
  final bool mediaBusy;
  final bool notificationsBusy;
  final VoidCallback onRequestMedia;
  final VoidCallback onRequestNotifications;

  @override
  Widget build(BuildContext context) {
    return _Page(
      asset: 'assets/images/ducks/duck_loading.png',
      title: strings.translate('onbPermsTitle'),
      body: strings.translate('onbPermsBody'),
      colors: colors,
      children: [
        EntranceFade(
          index: 3,
          child: _PermissionCard(
            icon: Icons.perm_media_rounded,
            title: strings.translate('onbPermMediaTitle'),
            body: strings.translate('onbPermMediaBody'),
            granted: mediaGranted,
            busy: mediaBusy,
            onGrant: onRequestMedia,
            colors: colors,
            isLight: isLight,
            strings: strings,
          ),
        ),
        const SizedBox(height: 12),
        // Shown on every version. Android 12 and below grant notifications at
        // install time, so `_refreshPermissionStates` finds it already granted
        // and the card renders as "Allowed" rather than as a dead button.
        EntranceFade(
          index: 4,
          child: _PermissionCard(
            icon: Icons.notifications_active_rounded,
            title: strings.translate('onbPermNotifTitle'),
            body: strings.translate('onbPermNotifBody'),
            granted: notificationsGranted,
            busy: notificationsBusy,
            onGrant: onRequestNotifications,
            colors: colors,
            isLight: isLight,
            strings: strings,
          ),
        ),
        const SizedBox(height: 16),
        EntranceFade(
          index: 5,
          child: Text(
            strings.translate('onbPermsSkipNote'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colors.textMuted,
              fontSize: 12.5,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.granted,
    required this.busy,
    required this.onGrant,
    required this.colors,
    required this.isLight,
    required this.strings,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool granted;
  final bool busy;
  final VoidCallback onGrant;
  final DuckColors colors;
  final bool isLight;
  final AppLocalizations strings;

  @override
  Widget build(BuildContext context) {
    return DuckLiquidGlassTrack(
      borderRadius: 20,
      isLight: isLight,
      fallbackColor: colors.glassFill,
      fallbackBorderColor: colors.glassBorder,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: colors.gold.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, size: 20, color: colors.gold),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: colors.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    body,
                    style: TextStyle(
                      color: colors.textMuted,
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _GrantButton(
                    granted: granted,
                    busy: busy,
                    onGrant: onGrant,
                    colors: colors,
                    strings: strings,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GrantButton extends StatelessWidget {
  const _GrantButton({
    required this.granted,
    required this.busy,
    required this.onGrant,
    required this.colors,
    required this.strings,
  });

  final bool granted;
  final bool busy;
  final VoidCallback onGrant;
  final DuckColors colors;
  final AppLocalizations strings;

  @override
  Widget build(BuildContext context) {
    if (granted) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_rounded, size: 18, color: DuckColors.green),
          const SizedBox(width: 6),
          Text(
            strings.translate('onbPermGranted'),
            style: TextStyle(
              color: DuckColors.green,
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      );
    }

    return Pressable(
      onTap: busy ? null : onGrant,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: colors.gold.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(DuckColors.radiusPill),
          border: Border.all(color: colors.gold.withValues(alpha: 0.4)),
        ),
        child: busy
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(colors.gold),
                ),
              )
            : Text(
                strings.translate('onbPermGrant'),
                style: TextStyle(
                  color: colors.gold,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
      ),
    );
  }
}
