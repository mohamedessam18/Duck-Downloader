import 'package:flutter/material.dart';
import 'dart:io';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/download_store.dart';
import '../state/downloads_controller.dart';
import '../theme/duck_theme.dart';
import '../widgets/ambient_background.dart';
import '../widgets/duck_motion.dart';
import '../services/crash_reporting_service.dart';

/// Where the published policy lives.
///
/// The in-app copy this screen used to render as a dialog is gone: Play needs
/// a publicly reachable URL for the listing, it has to stay reachable for as
/// long as the app is published, and a second copy in the binary meant the two
/// could quietly disagree about what Duck does with your data.
const _privacyPolicyUrl = 'https://duckdownloader.site/privacy';
const _reportAdUrl = 'https://duckdownloader.site/report-ad';

/// Kept in step with pubspec.yaml by hand.
const _appVersion = '1.2.1';
const _appBuild = '10';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller, this.store});

  final DuckDownloadsController controller;

  /// Only needed by actions that write app-level flags, such as replaying the
  /// intro. Optional so the screen stays trivially constructible in tests.
  final DownloadStore? store;

  @override
  Widget build(BuildContext context) {
    final colors = DuckColors.of(context);
    final topInset = MediaQuery.paddingOf(context).top;

    return Scaffold(
      backgroundColor: colors.background,
      body: Stack(
        children: [
          // The same drifting wash the library sits on, so Settings stops
          // looking like a screen borrowed from a different app.
          Positioned.fill(
            child: AmbientBackground(
              padding: EdgeInsets.only(top: topInset),
              child: const SizedBox.expand(),
            ),
          ),
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              return CustomScrollView(
                slivers: [
                  _Header(colors: colors),
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      18,
                      4,
                      18,
                      28 + MediaQuery.paddingOf(context).bottom,
                    ),
                    sliver: SliverList.list(
                      children: [
                        EntranceFade(
                          index: 0,
                          child: _Group(
                            colors: colors,
                            icon: Icons.download_rounded,
                            label: 'Downloads',
                            children: [
                              _Toggle(
                                colors: colors,
                                icon: Icons.photo_library_outlined,
                                title: 'Auto-save to gallery',
                                subtitle:
                                    'Copy finished downloads into Photos and '
                                    'Music, where your other apps can see them.',
                                value: controller.autoSaveVideos,
                                onChanged: controller.toggleAutoSaveVideos,
                              ),
                              _Line(colors: colors),
                              _Toggle(
                                colors: colors,
                                icon: Icons.link_rounded,
                                title: 'Detect copied links',
                                subtitle:
                                    'Offer to download a link the moment you '
                                    'copy it somewhere else.',
                                value: controller.enableClipboardDetection,
                                onChanged: controller.toggleClipboardDetection,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 22),
                        EntranceFade(
                          index: 1,
                          child: _Group(
                            colors: colors,
                            icon: Icons.notifications_none_rounded,
                            label: 'Notifications',
                            children: [
                              _Action(
                                colors: colors,
                                icon: Icons.graphic_eq_rounded,
                                title: 'Sounds and alerts',
                                // Android owns this from version 8 on: a
                                // channel's sound is fixed at creation, and an
                                // app that overrides the user's choice is
                                // fighting the platform. So hand them the
                                // system's own control rather than a fake one.
                                subtitle:
                                    'Pick a sound, or silence Duck, in Android '
                                    'settings.',
                                onTap: controller.openDeviceMediaSettings,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 22),
                        EntranceFade(
                          index: 2,
                          child: _Group(
                            colors: colors,
                            icon: Icons.lock_outline_rounded,
                            label: 'Privacy',
                            children: [
                              _Toggle(
                                colors: colors,
                                icon: Icons.bug_report_outlined,
                                title: 'Send diagnostics',
                                // A toggle that is on while nothing is being
                                // sent is a lie the user cannot see through,
                                // so say when the reporter never came up.
                                subtitle:
                                    CrashReportingService.instance.available
                                        ? 'Anonymous crash reports only. Never '
                                            'your files, your links, or '
                                            'anything in the vault.'
                                        : 'Unavailable on this device — crash '
                                            'reporting could not start, so '
                                            'nothing is being sent.',
                                value: controller.crashReportingEnabled,
                                onChanged: controller.toggleCrashReporting,
                              ),
                              _Line(colors: colors),
                              _Action(
                                colors: colors,
                                icon: Icons.shield_outlined,
                                title: 'Privacy policy',
                                subtitle:
                                    'What Duck collects, and what it never '
                                    'touches.',
                                trailing: Icons.open_in_new_rounded,
                                onTap: () => _openPolicy(context),
                              ),
                              _Line(colors: colors),
                              _Action(
                                colors: colors,
                                icon: Icons.flag_outlined,
                                title: 'Report an ad',
                                subtitle:
                                    'Something offensive, a scam, or not '
                                    'suitable for this app.',
                                trailing: Icons.open_in_new_rounded,
                                onTap: () => _reportAd(context),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 22),
                        EntranceFade(
                          index: 3,
                          child: _Group(
                            colors: colors,
                            icon: Icons.info_outline_rounded,
                            label: 'About',
                            children: [
                              _Action(
                                colors: colors,
                                icon: Icons.replay_rounded,
                                title: 'Show the intro again',
                                subtitle:
                                    'Walk through what Duck can do, from the '
                                    'start.',
                                onTap: () => _replayIntro(context),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 30),
                        EntranceFade(index: 4, child: _Version(colors: colors)),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  /// Opens the report page with what the app knows and the user could not
  /// type accurately.
  ///
  /// Only facts about the app and the device: version, Android release, ad
  /// format, language, and when. Nothing that identifies the person — an
  /// advertiser gets blocked on the strength of "thirty people reported this",
  /// and a name would not make that decision any easier while making the log
  /// something worth stealing.
  ///
  /// The page shows every value and lets them drop the lot before sending, so
  /// this is an offer rather than a collection.
  Future<void> _reportAd(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final locale = Localizations.localeOf(context).languageCode;

    var version = '';
    try {
      final info = await PackageInfo.fromPlatform();
      version = '${info.version}+${info.buildNumber}';
    } catch (_) {
      // A missing version is not a reason to refuse the report.
    }

    final uri = Uri.parse(_reportAdUrl).replace(queryParameters: {
      if (version.isNotEmpty) 'appVersion': version,
      'platform': _deviceDescription(),
      'locale': locale,
      'seenAt': DateTime.now().toUtc().toIso8601String(),
    });

    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (!opened) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Open $_reportAdUrl in a browser.')),
      );
    }
  }

  /// "Android 13" rather than a fingerprint. Enough to reproduce an ad
  /// problem, not enough to pick one phone out of a crowd.
  String _deviceDescription() {
    if (!Platform.isAndroid && !Platform.isIOS) return 'Desktop';
    final version = Platform.operatingSystemVersion;
    final match = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(version);
    final release = match?.group(1);
    final name = Platform.isAndroid ? 'Android' : 'iOS';
    return release == null ? name : '$name $release';
  }

  Future<void> _openPolicy(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(_privacyPolicyUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      opened = false;
    }
    // A device with no browser, or one that is offline, must not be left
    // tapping a row that silently does nothing — show the address instead.
    if (!opened) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Open $_privacyPolicyUrl in a browser.')),
      );
    }
  }

  Future<void> _replayIntro(BuildContext context) async {
    final store = this.store;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (store == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('The intro is not available here.')),
      );
      return;
    }
    await store.writeOnboardingCompleted(false);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('The intro will show next time you open Duck.'),
      ),
    );
    navigator.maybePop();
  }
}

// ── Header ──────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({required this.colors});

  final DuckColors colors;

  @override
  Widget build(BuildContext context) {
    return SliverAppBar(
      pinned: true,
      expandedHeight: 132,
      backgroundColor: colors.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      iconTheme: IconThemeData(color: colors.text),
      flexibleSpace: FlexibleSpaceBar(
        titlePadding: const EdgeInsetsDirectional.only(start: 56, bottom: 14),
        title: Text(
          'Settings',
          style: TextStyle(
            color: colors.text,
            fontSize: 21,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
          ),
        ),
        background: Align(
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 22, bottom: 10),
            child: Icon(
              Icons.tune_rounded,
              size: 62,
              color: colors.gold.withValues(alpha: 0.13),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Group ───────────────────────────────────────────────────────────────────

class _Group extends StatelessWidget {
  const _Group({
    required this.colors,
    required this.icon,
    required this.label,
    required this.children,
  });

  final DuckColors colors;
  final IconData icon;
  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 10),
          child: Row(
            children: [
              Icon(icon, size: 15, color: colors.gold),
              const SizedBox(width: 7),
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  color: colors.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.3,
                ),
              ),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: colors.panel.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(DuckColors.radiusLg),
            border: Border.all(color: colors.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(children: children),
        ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.colors});

  final DuckColors colors;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 62),
        child: Divider(height: 1, thickness: 1, color: colors.divider),
      );
}

/// The gold-tinted rounded square every row leads with.
class _Glyph extends StatelessWidget {
  const _Glyph({required this.colors, required this.icon});

  final DuckColors colors;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: colors.gold.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Icon(icon, color: colors.gold, size: 18),
    );
  }
}

class _RowText extends StatelessWidget {
  const _RowText({
    required this.colors,
    required this.title,
    required this.subtitle,
  });

  final DuckColors colors;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: colors.text,
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.1,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          subtitle,
          style: TextStyle(
            color: colors.textMuted,
            fontSize: 12.5,
            height: 1.38,
          ),
        ),
      ],
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.colors,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final DuckColors colors;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      pressedScale: 1,
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Glyph(colors: colors, icon: icon),
            const SizedBox(width: 14),
            Expanded(
              child: _RowText(
                colors: colors,
                title: title,
                subtitle: subtitle,
              ),
            ),
            const SizedBox(width: 10),
            Switch(
              value: value,
              // activeColor was deprecated after 3.31; activeThumbColor is the
              // replacement the analyzer asks for.
              activeThumbColor: colors.gold,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.colors,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing = Icons.chevron_right_rounded,
  });

  final DuckColors colors;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final IconData trailing;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      pressedScale: 1,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Glyph(colors: colors, icon: icon),
            const SizedBox(width: 14),
            Expanded(
              child: _RowText(
                colors: colors,
                title: title,
                subtitle: subtitle,
              ),
            ),
            const SizedBox(width: 10),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Icon(trailing, size: 19, color: colors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _Version extends StatelessWidget {
  const _Version({required this.colors});

  final DuckColors colors;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: colors.gold.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(DuckColors.radiusPill),
              border: Border.all(color: colors.gold.withValues(alpha: 0.22)),
            ),
            child: Text(
              'v$_appVersion  ·  build $_appBuild',
              style: TextStyle(
                color: colors.gold,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Made for people who keep their own files.',
            style: TextStyle(color: colors.textMuted, fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}
