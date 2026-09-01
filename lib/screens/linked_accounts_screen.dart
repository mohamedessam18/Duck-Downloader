import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/platform_sessions.dart';
import '../state/downloads_controller.dart';
import '../theme/duck_theme.dart';
import '../widgets/ambient_background.dart';
import '../widgets/duck_motion.dart';
import 'platform_login_screen.dart';

/// Shows which sites Duck is signed into, and lets the user undo that.
///
/// Before this existed there was no way to see a saved session and no way to
/// remove one short of clearing the app's data — for logins the app had
/// collected on the user's behalf, from a screen that appeared on its own
/// after a failed download. Somewhere to say "not this one, and not any more"
/// is the other half of being allowed to store them at all.
class LinkedAccountsScreen extends StatefulWidget {
  const LinkedAccountsScreen({super.key, required this.controller});

  /// Signing out goes through the controller rather than the store directly.
  /// The on-device YouTube extractor is handed the session at startup and
  /// keeps it in memory, so clearing storage alone left it signed in until the
  /// app was restarted.
  final DuckDownloadsController controller;

  @override
  State<LinkedAccountsScreen> createState() => _LinkedAccountsScreenState();
}

class _LinkedAccountsScreenState extends State<LinkedAccountsScreen> {
  Set<SocialPlatform>? _signedIn;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final signedIn = await widget.controller.signedInPlatforms();
    if (mounted) setState(() => _signedIn = signedIn);
  }

  Future<void> _signIn(SocialPlatform platform) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PlatformLoginScreen(platform: platform),
      ),
    );
    await _refresh();
  }

  Future<void> _signOut(SocialPlatform platform) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await widget.controller.signOutOf(platform);
    await _refresh();
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.translate('accountsCleared'))),
    );
  }

  Future<void> _signOutAll() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final colors = DuckColors.of(context);
        return AlertDialog(
          backgroundColor: colors.panel,
          title: Text(
            l10n.translate('accountsSignOutAll'),
            style: TextStyle(color: colors.text, fontWeight: FontWeight.w800),
          ),
          content: Text(
            l10n.translate('accountsSignOutAllBody'),
            style: TextStyle(color: colors.textMuted, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.translate('cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(foregroundColor: DuckColors.danger),
              child: Text(l10n.translate('accountsSignOutAllConfirm')),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    await widget.controller.signOutOfEverything();
    await _refresh();
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.translate('accountsCleared'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = DuckColors.of(context);
    final l10n = AppLocalizations.of(context);
    final signedIn = _signedIn;
    final topInset = MediaQuery.paddingOf(context).top;

    return Scaffold(
      backgroundColor: colors.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: AmbientBackground(
              padding: EdgeInsets.only(top: topInset),
              child: const SizedBox.expand(),
            ),
          ),
          CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                backgroundColor: colors.background.withValues(alpha: 0.92),
                foregroundColor: colors.text,
                elevation: 0,
                title: Text(
                  l10n.translate('accountsTitle'),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  18,
                  6,
                  18,
                  28 + MediaQuery.paddingOf(context).bottom,
                ),
                sliver: SliverList.list(
                  children: [
                    EntranceFade(
                      index: 0,
                      child: _Assurance(
                        colors: colors,
                        text: l10n.translate('accountsNote'),
                      ),
                    ),
                    const SizedBox(height: 18),
                    if (signedIn == null)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 40),
                          child: CircularProgressIndicator(color: colors.gold),
                        ),
                      )
                    else ...[
                      EntranceFade(
                        index: 1,
                        child: Container(
                          decoration: BoxDecoration(
                            color: colors.panel.withValues(alpha: 0.72),
                            borderRadius: BorderRadius.circular(
                              DuckColors.radiusLg,
                            ),
                            border: Border.all(color: colors.border),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            children: [
                              for (
                                var i = 0;
                                i < allPlatformProfiles.length;
                                i++
                              ) ...[
                                if (i > 0)
                                  Divider(
                                    height: 1,
                                    thickness: 1,
                                    color: colors.divider,
                                  ),
                                _AccountRow(
                                  colors: colors,
                                  l10n: l10n,
                                  profile: allPlatformProfiles[i],
                                  isSignedIn: signedIn.contains(
                                    allPlatformProfiles[i].platform,
                                  ),
                                  onSignIn: () =>
                                      _signIn(allPlatformProfiles[i].platform),
                                  onSignOut: () =>
                                      _signOut(allPlatformProfiles[i].platform),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 22),
                      if (signedIn.isNotEmpty)
                        EntranceFade(
                          index: 2,
                          child: SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: _signOutAll,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: DuckColors.danger,
                                side: const BorderSide(
                                  color: DuckColors.danger,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                    DuckColors.radiusPill,
                                  ),
                                ),
                              ),
                              icon: const Icon(Icons.logout_rounded, size: 18),
                              label: Text(
                                l10n.translate('accountsSignOutAll'),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Assurance extends StatelessWidget {
  const _Assurance({required this.colors, required this.text});

  final DuckColors colors;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: DuckColors.green.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(DuckColors.radiusLg),
        border: Border.all(color: DuckColors.green.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lock_outline, size: 18, color: DuckColors.green),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: colors.textMuted,
                fontSize: 12.5,
                height: 1.55,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.colors,
    required this.l10n,
    required this.profile,
    required this.isSignedIn,
    required this.onSignIn,
    required this.onSignOut,
  });

  final DuckColors colors;
  final AppLocalizations l10n;
  final PlatformProfile profile;
  final bool isSignedIn;
  final VoidCallback onSignIn;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isSignedIn ? DuckColors.green : colors.border,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profile.label,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.translate(
                    isSignedIn ? 'accountsSignedIn' : 'accountsSignedOut',
                  ),
                  style: TextStyle(
                    color: isSignedIn ? DuckColors.green : colors.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Pressable(
            pressedScale: 1,
            onTap: isSignedIn ? onSignOut : onSignIn,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(
                l10n.translate(
                  isSignedIn ? 'accountsSignOut' : 'accountsSignIn',
                ),
                style: TextStyle(
                  color: isSignedIn ? DuckColors.danger : colors.gold,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
