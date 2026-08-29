import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'dart:async';
import 'package:local_auth/local_auth.dart';
import 'package:file_picker/file_picker.dart';
import '../services/camera_service.dart';
import 'package:path/path.dart' as p;

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import '../l10n/app_localizations.dart';
import '../models/browser_image_candidate.dart';
import '../models/download_models.dart';
import '../services/premium_entitlement.dart';
import '../constants/asset_paths.dart';
import '../core/duck_page_route.dart';
import '../core/haptics.dart';
import '../core/plurals.dart';
import 'device_folder_sheet.dart';
import '../widgets/duck_empty_state.dart';
import '../widgets/duck_motion.dart';
import '../state/downloads_controller.dart';
import '../services/device_media_service.dart';
import '../services/download_store.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../core/permissions/permission_service.dart';
import '../services/vault_encryption_service.dart';
import '../widgets/ambient_background.dart';
import '../widgets/animated_duck.dart';
import '../widgets/duck_liquid_glass.dart';
import '../widgets/glass_panel.dart';
import '../widgets/media/media_thumb.dart';
import '../widgets/media/mini_player.dart';
import '../services/ad_service.dart';
import 'locked_social_browser_screen.dart';
import 'settings_screen.dart';


/// Digits in a vault passcode.
///
/// Taken from the encryption service rather than written here, because these
/// two had drifted: the keypad submitted at 4 digits while the service required
/// 6, so every attempt to create a vault was rejected as too short and the
/// feature was unusable. One source of truth stops that recurring.
const int _pinLength = VaultEncryptionService.minimumPinLength;

bool get _isLight {
  try {
    return PlatformDispatcher.instance.platformBrightness == Brightness.light;
  } catch (_) {
    return false;
  }
}

Color get _gold => _isLight ? const Color(0xFFC69214) : const Color(0xFFFFC52F);
Color get _warmGold =>
    _isLight ? const Color(0xFFB58032) : const Color(0xFFF6BD6A);
Color get _dark => _isLight ? const Color(0xFFF5F6F8) : const Color(0xFF101112);
Color get _nav => _isLight ? const Color(0xFFFFFFFF) : const Color(0xFF171819);
Color get _panel =>
    _isLight ? const Color(0xFFFFFFFF) : const Color(0xFF1D1D1F);
Color get _muted =>
    _isLight ? const Color(0xFF6F707A) : const Color(0xFFB8B8B8);
Color get _text => _isLight ? const Color(0xFF151517) : const Color(0xFFFFFFFF);
Color get _textMuted =>
    _isLight ? const Color(0xFF5A5A62) : const Color(0xFFB8B8B8);
Color get _border => _isLight
    ? Colors.black.withValues(alpha: 0.08)
    : Colors.white.withValues(alpha: 0.08);
Color get _divider => _isLight
    ? Colors.black.withValues(alpha: 0.06)
    : Colors.white.withValues(alpha: 0.08);
const _danger = Color(0xFFFF7A65);
const _green = Color(0xFF41D27D);

class DuckAppScreen extends StatefulWidget {
  const DuckAppScreen({super.key, required this.controller});

  final DuckDownloadsController controller;

  @override
  State<DuckAppScreen> createState() => _DuckAppScreenState();
}

class _DuckAppScreenState extends State<DuckAppScreen> {
  DuckFlow? _prevFlow;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.controller.isPremiumActive) return;
      if (!widget.controller.consumePendingPremiumOffer()) return;
      showPremiumSheet(context, widget.controller);
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChange);
    super.dispose();
  }

  void _onControllerChange() {
    if (!mounted) return;

    if (widget.controller.isAdultContentBlocked) {
      widget.controller.isAdultContentBlocked = false;
      _showAdultContentWarningDialog(context);
      return;
    }

    if (widget.controller.showAdOnOpen) {
      widget.controller.showAdOnOpen = false;
      AdService.instance.showInterstitialAd(
        isPremiumActive: widget.controller.isPremiumActive,
        onAdClosed: () {},
      );
    }

    final currentFlow = widget.controller.flow;
    if (_prevFlow != currentFlow) {
      final l10n = AppLocalizations.of(context);
      if (currentFlow == DuckFlow.success) {
        DuckHaptics.success();
        _showSettingToast(context, l10n.translate('statusComplete'), true);
      } else if (currentFlow == DuckFlow.error) {
        DuckHaptics.error();
        // `status` is the English form on purpose here: these two are internal
        // markers thrown as exceptions, not sentences anyone should read.
        final marker = widget.controller.status;
        if (marker.contains('BLOCKED_ADULT_CONTENT')) {
          // Already handled by the dialog above.
        } else if (marker.contains('ADULT_CHECK_UNAVAILABLE')) {
          _showSettingToast(
            context,
            l10n.translate('statusAdultCheckUnavailable'),
            false,
          );
        } else {
          final text = widget.controller.statusMessage.resolve(l10n);
          if (text.isNotEmpty && text != 'null') {
            _showSettingToast(context, text, false);
          }
        }
      }
      _prevFlow = currentFlow;
    }
  }

  void _showAdultContentWarningDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: _panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: _danger.withOpacity(0.5), width: 2),
          ),
          title: Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: _danger, size: 28),
              const SizedBox(width: 12),
              Text(
                'تنبيه هام',
                style: TextStyle(
                  color: _text,
                  fontWeight: FontWeight.bold,
                  fontSize: 20,
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _danger.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _danger.withOpacity(0.15)),
                ),
                child: Text(
                  'تنبيه لحماية خصوصيتك وصحتك النفسية',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _danger,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    height: 1.5,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'الإباحية سجن نفسي وعقلي يستنزف طاقتك وشبابك. الإقلاع عنها هو خطوتك الأولى لاستعادة توازنك النفسي وحريتك الشخصية والاستمتاع بحياتك الحقيقية. لحمايتك وحماية خصوصيتك، تم حظر هذا المحتوى بالكامل.',
                textAlign: TextAlign.center,
                style: TextStyle(color: _text, fontSize: 14, height: 1.6),
              ),
            ],
          ),
          actions: [
            Center(
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _danger,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    'موافق',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openLockedBrowser(
    BuildContext context,
    LockedBrowserRequest request,
  ) async {
    if (widget.controller.lockedBrowserRequest != request) return;
    widget.controller.clearLockedBrowserRequest();
    final result = await Navigator.of(context).push<dynamic>(
      DuckPageRoute(
        builder: (_) => LockedSocialBrowserScreen(
          initialUrl: request.url,
          platform: request.platform,
          controller: widget.controller,
        ),
      ),
    );
    if (!context.mounted || result == null) return;
    if (result is String) {
      // fromLockedBrowser: true prevents re-opening the browser on failure
      await widget.controller.extractUrl(result, fromLockedBrowser: true);
    } else if (result is List<BrowserImageCandidate>) {
      if (result.isEmpty) return;
      await widget.controller.startBrowserImageDownloads(
        candidates: result,
        platform: request.platform,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final browserRequest = widget.controller.lockedBrowserRequest;
        if (browserRequest != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) {
              unawaited(_openLockedBrowser(context, browserRequest));
            }
          });
        }

        final isAndroid = Theme.of(context).platform == TargetPlatform.android;
        final canPop =
            !isAndroid &&
            !widget.controller.hasBackInterceptors &&
            widget.controller.playerItem == null &&
            widget.controller.detectedClipboardUrl == null &&
            widget.controller.tab == DuckTab.home &&
            widget.controller.tabHistory.isEmpty;

        return PopScope(
          canPop: canPop,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;

            // 0. Innermost first. Anything that owns a dismissible layer of
            // its own — the player's option panels, its landscape mode, its
            // screen lock — registers with the controller and gets asked
            // before the coarse rules below run. Without this, back skipped
            // straight past whatever the user was actually looking at.
            if (widget.controller.handleBackIntercept()) return;

            // 1. If player is open, close it
            if (widget.controller.playerItem != null) {
              widget.controller.closePlayer();
              return;
            }

            // 2. If clipboard overlay is open, dismiss it
            if (widget.controller.detectedClipboardUrl != null) {
              widget.controller.dismissClipboardDetection();
              return;
            }

            // 3. Otherwise pop tab history (on Android, directly jump to Home tab)
            if (isAndroid && widget.controller.tab != DuckTab.home) {
              widget.controller.tabHistory.clear();
              widget.controller.setTab(DuckTab.home);
              return;
            }

            // 4. Double-back to exit on Android when on Home tab with empty history
            if (isAndroid &&
                widget.controller.tab == DuckTab.home &&
                widget.controller.tabHistory.isEmpty) {
              final shouldExit = widget.controller.handleDoubleBackToExit();
              if (shouldExit) {
                SystemNavigator.pop();
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Press back again to exit'),
                    duration: Duration(seconds: 2),
                  ),
                );
              }
              return;
            }

            widget.controller.popTabHistory();
          },
          child: Scaffold(
            backgroundColor: widget.controller.isQuickShareMode
                ? Colors.transparent
                : _dark,
            body: Stack(
              children: [
                if (!widget.controller.isQuickShareMode)
                  Positioned.fill(
                    child: AmbientBackground(
                      padding: EdgeInsets.only(
                        top: MediaQuery.paddingOf(context).top,
                        bottom:
                            widget.controller.playingItem != null &&
                                widget.controller.playerItem == null
                            ? 80
                            : 0,
                      ),
                      child: _bodyForTab(context),
                    ),
                  ),
                if (!widget.controller.isQuickShareMode &&
                    widget.controller.playingItem != null &&
                    widget.controller.playerItem == null)
                  Builder(
                    builder: (context) {
                      final bottomShift = 68.0;
                      return Positioned(
                        bottom:
                            bottomShift + MediaQuery.paddingOf(context).bottom,
                        left: 16,
                        right: 16,
                        child: MiniPlayer(controller: widget.controller),
                      );
                    },
                  ),
                if (widget.controller.detectedClipboardUrl != null)
                  _ClipboardDetectorOverlay(
                    url: widget.controller.detectedClipboardUrl!,
                    onDismiss: widget.controller.dismissClipboardDetection,
                    onAccept: widget.controller.acceptClipboardDetection,
                  ),
                if (widget.controller.sharedQuickDownloadUrl != null)
                  _QuickShareOverlay(
                    url: widget.controller.sharedQuickDownloadUrl!,
                    controller: widget.controller,
                    onDismiss: () {
                      widget.controller.dismissQuickShare();
                    },
                    onAcceptFormat: (format, type) {
                      widget.controller.acceptQuickShareDownloadWithFormat(
                        format,
                        type,
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Downloading in ${format.label}...'),
                          backgroundColor: const Color(0xFF101112),
                          duration: const Duration(seconds: 3),
                        ),
                      );
                    },
                    onAcceptDefault: (type) {
                      widget.controller.acceptQuickShareDownload(type);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Downloading...'),
                          backgroundColor: Color(0xFF101112),
                          duration: Duration(seconds: 3),
                        ),
                      );
                    },
                  ),
                if (widget.controller.showPlaylistChoiceDialog)
                  _PlaylistChoiceOverlay(controller: widget.controller),
                if (!widget.controller.isQuickShareMode &&
                    widget.controller.playerItem == null &&
                    MediaQuery.viewInsetsOf(context).bottom == 0)
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: _BottomNavBar(controller: widget.controller),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Left-to-right position of a tab in the nav bar.
  ///
  /// Deliberately not `DuckTab.index`: the enum is declared
  /// `home, videos, audios, images` while the bar reads HOME, IMAGES, VIDEOS,
  /// AUDIOS. Driving the slide direction off the enum would send the page
  /// leftwards for a tab sitting to the right, which reads as a glitch rather
  /// than as movement.
  static int _navOrder(DuckTab tab) => switch (tab) {
    DuckTab.home => 0,
    DuckTab.images => 1,
    DuckTab.videos => 2,
    DuckTab.audios => 3,
  };

  /// Which way the current tab change travels: 1 rightwards, -1 leftwards.
  int _tabSlide = 1;
  DuckTab? _renderedTab;

  Widget _bodyForTab(BuildContext context) {
    final tab = widget.controller.tab;
    final previous = _renderedTab;
    if (previous != null && previous != tab) {
      _tabSlide = _navOrder(tab) > _navOrder(previous) ? 1 : -1;
    }
    _renderedTab = tab;
    final key = ValueKey(tab);

    return AnimatedSwitcher(
      duration: DuckMotion.transitionDuration,
      switchInCurve: DuckMotion.transitionCurve,
      switchOutCurve: DuckMotion.transitionCurve,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.expand,
        alignment: Alignment.topCenter,
        children: [...previousChildren, ?currentChild],
      ),
      transitionBuilder: (child, animation) {
        // The outgoing child keeps its own animation running backwards, so it
        // needs the opposite offset: the pair should travel together in one
        // direction, like a strip being pulled across, rather than both
        // arriving from the same side.
        final leaving = child.key != key;
        final from = leaving ? -_tabSlide.toDouble() : _tabSlide.toDouble();
        return SlideTransition(
          position: Tween<Offset>(
            begin: Offset(from, 0),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        );
      },
      child: KeyedSubtree(key: key, child: _tabBody()),
    );
  }

  Widget _tabBody() {
    return switch (widget.controller.tab) {
      DuckTab.home => _HomeView(controller: widget.controller),
      DuckTab.images => _LibraryView(
        title: 'IMAGES',
        items: widget.controller.images,
        emptyTitle: 'No images yet',
        emptyMessage:
            'Photos and carousels you download will land here, ready to view '
            'or save to your gallery.',
        emptyIcon: Icons.photo_library_outlined,
        controller: widget.controller,
      ),
      DuckTab.videos => _LibraryView(
        title: 'VIDEOS',
        items: widget.controller.videos,
        emptyTitle: 'No videos yet',
        emptyMessage:
            'Copy a link from YouTube, Instagram, TikTok, Reddit or X, then '
            'tap the duck to grab it.',
        emptyIcon: Icons.movie_outlined,
        controller: widget.controller,
      ),
      DuckTab.audios => _LibraryView(
        title: 'AUDIOS',
        items: widget.controller.audios,
        emptyTitle: 'No audio yet',
        emptyMessage:
            'Pick Audio when you download, or convert any video you already '
            'have into a track.',
        emptyIcon: Icons.library_music_outlined,
        controller: widget.controller,
      ),
    };
  }
}

class _HomeView extends StatelessWidget {
  const _HomeView({required this.controller});

  final DuckDownloadsController controller;

  @override
  Widget build(BuildContext context) {
    final active = controller.activeDownload;
    final activeDownloads = controller.activeDownloads;
    final showQueue = activeDownloads.length > 1 && controller.metadata == null;
    final scale = (MediaQuery.sizeOf(context).height / 820).clamp(.78, 1.0);
    return Stack(
      children: [
        Positioned.fill(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              28,
              showQueue ? 14 : 22,
              28,
              130 * scale,
            ),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _AutoSaveToggle(controller: controller),
                      _ClipboardToggle(controller: controller),
                      _SettingsButton(controller: controller),
                      _ProBadge(controller: controller),
                    ],
                  ),
                ),
                SizedBox(height: (showQueue ? 8 : 12) * scale),
                _Brand(compact: showQueue, scale: scale),
                SizedBox(height: (showQueue ? 16 : 26) * scale),
                AnimatedDuck(
                  flow: controller.flow,
                  compact: showQueue,
                  scale: scale,
                  onTap: controller.pasteAndExtract,
                ),
                if (controller.lastDownloadedItem != null) ...[
                  const SizedBox(height: 12),
                  IconButton(
                    onPressed: controller.shareLastDownloadedItem,
                    icon: Icon(Icons.ios_share, color: _gold, size: 28),
                  ),
                ],
                _StatusBar(
                  flow: controller.flow,
                  status: controller.statusMessage.resolve(
                    AppLocalizations.of(context),
                  ),
                  progress: active?.progress ?? 0,
                ),
                // Was `status.toLowerCase().contains('in-app browser')`, so
                // the login button existed only as long as that exact English
                // wording did — translating the message would have removed the
                // only way out of the error it describes.
                if (controller.needsBrowserLogin) ...[
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: const Color(0xFF101112),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                    ),
                    onPressed: () {
                      final url =
                          controller.lastAttemptedUrl ??
                          'https://www.instagram.com';
                      final lower = url.toLowerCase();
                      final platform = lower.contains('instagram')
                          ? 'Instagram'
                          : lower.contains('facebook')
                          ? 'Facebook'
                          : lower.contains('youtube')
                          ? 'YouTube'
                          : lower.contains('twitter') || lower.contains('x.com')
                          ? 'X'
                          : 'Social';
                      controller.lockedBrowserRequest = LockedBrowserRequest(
                        url: url,
                        platform: platform,
                      );
                    },
                    icon: const Icon(Icons.open_in_browser),
                    label: const Text(
                      'Open In-App Browser',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ],
                if (controller.metadata != null)
                  _OptionsCard(controller: controller)
                else if (controller.batchItems != null)
                  _BatchOptionsCard(controller: controller)
                else if (showQueue)
                  _DownloadQueueCard(
                    controller: controller,
                    items: activeDownloads,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.compact, required this.scale});

  final bool compact;
  final double scale;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) => LinearGradient(
            colors: [_gold, _warmGold, _gold],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ).createShader(bounds),
          child: Text(
            'DUCK DOWNLOADER',
            style: TextStyle(
              color: Colors.white,
              fontSize: (compact ? 22 : 26) * scale,
              letterSpacing: 6,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
        const SizedBox(height: 6),
        // The tagline, not a second copy of the wordmark's last word. This
        // used to read "DOWNLOADER" directly under "DUCK DOWNLOADER", which
        // looked like a rendering fault rather than a subtitle.
        //
        // FittedBox because the line is now three words instead of one: at
        // this letter spacing it would otherwise overflow on a narrow phone,
        // and trading a duplicated word for a clipped one is no trade at all.
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            'COPY. DETECT. DOWNLOAD.',
            style: TextStyle(
              color: _textMuted.withValues(alpha: 0.85),
              fontSize: (compact ? 10 : 12) * scale,
              letterSpacing: 4,
              fontWeight: FontWeight.w300,
            ),
          ),
        ),
      ],
    );
  }
}

void _showSettingToast(BuildContext context, String message, bool enabled) {
  ScaffoldMessenger.of(context).clearSnackBars();

  final isLight = Theme.of(context).brightness == Brightness.light;

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      behavior: SnackBarBehavior.floating,
      padding: EdgeInsets.zero,
      duration: const Duration(seconds: 2),
      content: DuckLiquidGlassSurface(
        borderRadius: 16,
        isLight: isLight,
        variant: DuckLiquidGlassVariant.panel,
        fallbackColor: const Color(0xFF1B1C1D).withOpacity(0.85),
        fallbackBorderColor: Colors.white.withOpacity(0.08),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.24),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                enabled ? Icons.check_circle : Icons.cancel,
                color: enabled
                    ? const Color(0xFF2ECC71)
                    : const Color(0xFFE74C3C),
                size: 22,
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _AutoSaveToggle extends StatelessWidget {
  const _AutoSaveToggle({required this.controller});

  final DuckDownloadsController controller;

  @override
  Widget build(BuildContext context) {
    return _HeaderToggle(
      icon: controller.autoSaveVideos
          ? Icons.save_alt
          : Icons.save_alt_outlined,
      label: 'AUTO SAVE',
      active: controller.autoSaveVideos,
      onTap: () {
        final newStatus = !controller.autoSaveVideos;
        controller.toggleAutoSaveVideos(newStatus);
        _showSettingToast(
          context,
          newStatus ? 'Auto Save Enabled' : 'Auto Save Disabled',
          newStatus,
        );
      },
    );
  }
}

class _ClipboardToggle extends StatelessWidget {
  const _ClipboardToggle({required this.controller});

  final DuckDownloadsController controller;

  @override
  Widget build(BuildContext context) {
    return _HeaderToggle(
      icon: controller.enableClipboardDetection
          ? Icons.content_paste_search
          : Icons.content_paste_off,
      label: 'CLIPBOARD',
      active: controller.enableClipboardDetection,
      onTap: () {
        final newStatus = !controller.enableClipboardDetection;
        controller.toggleEnableClipboardDetection(newStatus);
        _showSettingToast(
          context,
          newStatus
              ? 'Clipboard Detection Enabled'
              : 'Clipboard Detection Disabled',
          newStatus,
        );
      },
    );
  }
}

class _SettingsButton extends StatelessWidget {
  const _SettingsButton({required this.controller});

  final DuckDownloadsController controller;

  @override
  Widget build(BuildContext context) {
    return _HeaderToggle(
      icon: Icons.settings_outlined,
      label: 'SETTINGS',
      active: false,
      onTap: () {
        Navigator.of(context).push(
          DuckPageRoute(
            builder: (_) => SettingsScreen(
              controller: controller,
              // Replaying the intro flips an app-level flag rather than any
              // controller state, so the screen needs the store directly.
              store: DownloadStore(Hive.box('duck-downloads')),
            ),
          ),
        );
      },
    );
  }
}

class _HeaderToggle extends StatefulWidget {
  const _HeaderToggle({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_HeaderToggle> createState() => _HeaderToggleState();
}

class _HeaderToggleState extends State<_HeaderToggle> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final useLiquidEffects = !reduceMotion;
    final isLight = Theme.of(context).brightness == Brightness.light;

    final baseColor = widget.active ? _green : Colors.white;
    final containerColor = widget.active
        ? _green.withOpacity(isLight ? 0.24 : 0.16)
        : Colors.white.withOpacity(0.06);

    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _isPressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            boxShadow: useLiquidEffects
                ? [
                    BoxShadow(
                      color: baseColor.withOpacity(widget.active ? 0.24 : 0.08),
                      blurRadius: widget.active ? 10 : 4,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: useLiquidEffects
                ? BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: _buildContent(isLight, baseColor, containerColor),
                  )
                : _buildContent(
                    isLight,
                    baseColor,
                    containerColor,
                    noBlur: true,
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(
    bool isLight,
    Color baseColor,
    Color containerColor, {
    bool noBlur = false,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: containerColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: baseColor.withOpacity(widget.active ? 0.38 : 0.12),
          width: 1,
        ),
        gradient: (widget.active && !noBlur)
            ? LinearGradient(
                colors: [Colors.white.withOpacity(0.12), Colors.transparent],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              widget.icon,
              color: widget.active
                  ? _green
                  : (isLight ? Colors.black54 : Colors.white60),
              size: 17,
            ),
            const SizedBox(width: 7),
            Text(
              widget.label,
              style: TextStyle(
                color: widget.active
                    ? (isLight
                          ? const Color(0xFF0F3A1B)
                          : const Color(0xFFEAF8EE))
                    : (isLight ? Colors.black87 : const Color(0xFFE8E8E8)),
                fontSize: 12,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProBadge extends StatefulWidget {
  const _ProBadge({required this.controller});

  final DuckDownloadsController controller;

  @override
  State<_ProBadge> createState() => _ProBadgeState();
}

class _ProBadgeState extends State<_ProBadge> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.controller.isPremiumActive;
    final hasStudio = widget.controller.hasMusicRemovalSubscription;
    final isLight = Theme.of(context).brightness == Brightness.light;
    final l10n = AppLocalizations.of(context);
    final label = (hasStudio
            ? l10n.translate('payTierStudio')
            : active
            ? l10n.translate('payTierPremium')
            : l10n.translate('badgePlans'))
        .toUpperCase();

    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final useLiquidEffects = !reduceMotion;

    final baseColor = active ? _gold : Colors.white;
    final containerColor = active
        ? _gold.withOpacity(isLight ? 0.24 : 0.16)
        : Colors.white.withOpacity(0.06);

    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      onTap: () => showPremiumSheet(context, widget.controller),
      child: AnimatedScale(
        scale: _isPressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            boxShadow: useLiquidEffects
                ? [
                    BoxShadow(
                      color: baseColor.withOpacity(active ? 0.24 : 0.08),
                      blurRadius: active ? 10 : 4,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: useLiquidEffects
                ? BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: _buildContent(
                      isLight,
                      active,
                      baseColor,
                      containerColor,
                      label: label,
                      hasStudio: hasStudio,
                    ),
                  )
                : _buildContent(
                    isLight,
                    active,
                    baseColor,
                    containerColor,
                    label: label,
                    hasStudio: hasStudio,
                    noBlur: true,
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(
    bool isLight,
    bool active,
    Color baseColor,
    Color containerColor, {
    required String label,
    required bool hasStudio,
    bool noBlur = false,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: containerColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: baseColor.withOpacity(active ? 0.38 : 0.12),
          width: 1,
        ),
        gradient: (active && !noBlur)
            ? LinearGradient(
                colors: [Colors.white.withOpacity(0.12), Colors.transparent],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasStudio
                  ? Icons.graphic_eq
                  : active
                  ? Icons.workspace_premium
                  : Icons.workspace_premium_outlined,
              color: active
                  ? _gold
                  : (isLight ? Colors.black54 : Colors.white60),
              size: 18,
            ),
            const SizedBox(width: 7),
            Text(
              // Their tier when they have one, and the door to the plans when
              // they do not. It used to read "Duck Premium" to a subscriber
              // and to someone who had never paid, which named neither of
              // them correctly once a second tier existed.
              label,
              style: TextStyle(
                color: active
                    ? (isLight ? const Color(0xFF3D2D03) : _gold)
                    : (isLight ? Colors.black87 : const Color(0xFFE8E8E8)),
                fontSize: 12,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens the subscription sheet.
///
/// Public because the first-run intro presents it once at the end, after the
/// three intro pages rather than as a fourth one — a paywall the user cannot
/// swipe past is the fastest way to get uninstalled.
void showPremiumSheet(
  BuildContext context,
  DuckDownloadsController controller,
) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _PremiumSheet(controller: controller),
  );
}

/// The paywall, for two tiers and five plans.
///
/// It used to be a flat stack of one button per product, which worked while
/// there were three of them and stopped working the moment Studio existed:
/// five buttons in a column say nothing about which tier a plan belongs to,
/// what the difference between them is, or which one the user is already on.
///
/// Tier first, then plan, then one action. Everything else — the benefit list,
/// the prices, the button's own label — follows from those two choices, so
/// there is only ever one thing to read next.
class _PremiumSheet extends StatefulWidget {
  const _PremiumSheet({required this.controller});

  final DuckDownloadsController controller;

  @override
  State<_PremiumSheet> createState() => _PremiumSheetState();
}

class _PremiumSheetState extends State<_PremiumSheet> {
  PremiumTier? _tier;
  SubscriptionPlan? _plan;

  DuckDownloadsController get _controller => widget.controller;

  /// The tier the sheet opens on.
  ///
  /// Someone already on Premium is here to see Studio — landing them on the
  /// tier they have bought makes them find the upgrade themselves.
  PremiumTier get _selectedTier {
    final chosen = _tier;
    if (chosen != null) return chosen;
    return _controller.hasMusicRemovalSubscription ||
            !_controller.isPremiumActive
        ? PremiumTier.premium
        : PremiumTier.studio;
  }

  List<SubscriptionPlan> _plansFor(PremiumTier tier) {
    final plans = tier == PremiumTier.studio
        ? [SubscriptionPlan.studioMonthly, SubscriptionPlan.studioYearly]
        : [
            SubscriptionPlan.monthly,
            SubscriptionPlan.yearly,
            SubscriptionPlan.lifetime,
          ];
    // A plan the store has not returned is a draft in Play, not an offer.
    return plans
        .where((plan) => _controller.subscriptionProduct(plan) != null)
        .toList();
  }

  SubscriptionPlan? _selectedPlan(List<SubscriptionPlan> available) {
    if (available.isEmpty) return null;
    final chosen = _plan;
    if (chosen != null && available.contains(chosen)) return chosen;
    // Yearly by default: it is the one worth choosing and the one that gets
    // skipped when monthly sits first and pre-selected.
    return available.firstWhere(
      (plan) =>
          plan == SubscriptionPlan.yearly ||
          plan == SubscriptionPlan.studioYearly,
      orElse: () => available.first,
    );
  }

  /// What the yearly plan actually saves, worked out from live store prices.
  int? _yearlySavingFor(PremiumTier tier) {
    final monthly = _controller.subscriptionProduct(
      tier == PremiumTier.studio
          ? SubscriptionPlan.studioMonthly
          : SubscriptionPlan.monthly,
    );
    final yearly = _controller.subscriptionProduct(
      tier == PremiumTier.studio
          ? SubscriptionPlan.studioYearly
          : SubscriptionPlan.yearly,
    );
    if (monthly == null || yearly == null) return null;
    if (monthly.rawPrice <= 0 || yearly.rawPrice <= 0) return null;
    final full = monthly.rawPrice * 12;
    if (yearly.rawPrice >= full) return null;
    final saving = ((1 - yearly.rawPrice / full) * 100).round();
    return saving > 0 ? saving : null;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context);
        final tier = _selectedTier;
        final plans = _plansFor(tier);
        final plan = _selectedPlan(plans);
        final product = plan == null
            ? null
            : _controller.subscriptionProduct(plan);

        final ownsThisTier =
            _controller.hasMusicRemovalSubscription ||
            (_controller.isPremiumActive && tier == PremiumTier.premium);

        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          child: Container(
            width: double.infinity,
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .88,
            ),
            decoration: BoxDecoration(
              color: _panel,
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: _border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .35),
                  blurRadius: 28,
                  offset: const Offset(0, -10),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _header(l10n, tier, ownsThisTier: ownsThisTier),
                    const SizedBox(height: 18),
                    _tierSwitch(l10n, tier),
                    const SizedBox(height: 18),
                    _benefits(l10n, tier),
                    const SizedBox(height: 18),
                    if (plans.isEmpty)
                      _PremiumMessage(
                        icon: Icons.info_outline,
                        color: _muted,
                        text: l10n.translate('payNoProducts'),
                      )
                    else
                      _planChips(l10n, tier, plans, plan),
                    if (_controller.premiumError != null) ...[
                      const SizedBox(height: 14),
                      _PremiumMessage(
                        icon: Icons.error_outline,
                        color: _danger,
                        text: _controller.premiumError!,
                      ),
                    ],
                    const SizedBox(height: 16),
                    _action(l10n, tier, plan, product, ownsThisTier: ownsThisTier),
                    const SizedBox(height: 8),
                    Center(
                      child: TextButton(
                        onPressed: _controller.premiumBusy
                            ? null
                            : _controller.restorePurchases,
                        child: Text(
                          l10n.translate('payRestore'),
                          style: TextStyle(
                            color: _muted,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────

  /// Names the tier the user is looking at, not the one they have bought.
  ///
  /// The title used to be fixed, so tapping over to Studio left "Duck
  /// Premium" sitting above a Studio price. The header answers "what is
  /// this?" and the line under it answers "where do I stand?" — two
  /// questions, two places, neither of them the tab bar's job.
  Widget _header(
    AppLocalizations l10n,
    PremiumTier tier, {
    required bool ownsThisTier,
  }) {
    final isStudio = tier == PremiumTier.studio;
    return Row(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: _gold.withValues(alpha: .16),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(
            isStudio ? Icons.graphic_eq : Icons.workspace_premium,
            color: _gold,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedSwitcher(
                duration: DuckMotion.pressDuration,
                child: Text(
                  l10n.translate(
                    isStudio ? 'payTitleDuckStudio' : 'payTitleDuckPremium',
                  ),
                  key: ValueKey(isStudio),
                  style: TextStyle(
                    color: _text,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Text(
                l10n.translate(
                  ownsThisTier ? 'paySubtitleActive' : 'paySubtitleFree',
                ),
                style: TextStyle(color: _muted, fontSize: 12),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: () => Navigator.pop(context),
          icon: Icon(Icons.close, color: _muted),
        ),
      ],
    );
  }

  // ── Tier switch ───────────────────────────────────────────────────────────

  Widget _tierSwitch(AppLocalizations l10n, PremiumTier selected) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _isLight
            ? Colors.black.withValues(alpha: .04)
            : Colors.white.withValues(alpha: .05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          for (final tier in PremiumTier.values)
            Expanded(
              child: _tierTab(l10n, tier, isSelected: tier == selected),
            ),
        ],
      ),
    );
  }

  Widget _tierTab(
    AppLocalizations l10n,
    PremiumTier tier, {
    required bool isSelected,
  }) {
    final isStudio = tier == PremiumTier.studio;
    return GestureDetector(
      onTap: () {
        DuckHaptics.tap();
        setState(() {
          _tier = tier;
          // The plan belongs to the tier; carrying a Premium plan across to
          // Studio would leave the sheet describing a product that is not on
          // this tab.
          _plan = null;
        });
      },
      child: AnimatedContainer(
        duration: DuckMotion.pressDuration,
        curve: DuckMotion.pressCurve,
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: isSelected ? _gold : Colors.transparent,
          borderRadius: BorderRadius.circular(13),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (isStudio) ...[
              Icon(
                Icons.auto_awesome,
                size: 14,
                color: isSelected ? const Color(0xFF151515) : _gold,
              ),
              const SizedBox(width: 6),
            ],
            Text(
              l10n.translate(isStudio ? 'payTierStudio' : 'payTierPremium'),
              style: TextStyle(
                color: isSelected ? const Color(0xFF151515) : _textMuted,
                fontSize: 14,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Benefits ──────────────────────────────────────────────────────────────

  Widget _benefits(AppLocalizations l10n, PremiumTier tier) {
    final faster = l10n
        .translate('payBenefitFaster')
        .replaceAll(
          '{premium}',
          '${DuckDownloadsController.premiumConcurrentDownloads}',
        )
        .replaceAll(
          '{free}',
          '${DuckDownloadsController.freeConcurrentDownloads}',
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PremiumBenefit(label: l10n.translate('payBenefitAdFree')),
        _PremiumBenefit(label: faster),
        if (tier == PremiumTier.studio) ...[
          const SizedBox(height: 2),
          Text(
            l10n.translate('payStudioIncludes'),
            style: TextStyle(
              color: _muted,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          _PremiumBenefit(
            label: l10n.translate('payBenefitMusic'),
            highlighted: true,
          ),
        ],
      ],
    );
  }

  // ── Plans ─────────────────────────────────────────────────────────────────

  Widget _planChips(
    AppLocalizations l10n,
    PremiumTier tier,
    List<SubscriptionPlan> plans,
    SubscriptionPlan? selected,
  ) {
    final saving = _yearlySavingFor(tier);
    return Row(
      children: [
        for (var i = 0; i < plans.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: _PlanChip(
              plan: plans[i],
              product: _controller.subscriptionProduct(plans[i]),
              isSelected: plans[i] == selected,
              savingPercent:
                  (plans[i] == SubscriptionPlan.yearly ||
                      plans[i] == SubscriptionPlan.studioYearly)
                  ? saving
                  : null,
              onTap: () {
                DuckHaptics.tap();
                setState(() => _plan = plans[i]);
              },
            ),
          ),
        ],
      ],
    );
  }

  // ── Action ────────────────────────────────────────────────────────────────

  Widget _action(
    AppLocalizations l10n,
    PremiumTier tier,
    SubscriptionPlan? plan,
    SubscriptionProduct? product, {
    required bool ownsThisTier,
  }) {
    if (_controller.hasMusicRemovalSubscription) {
      return _PremiumMessage(
        icon: Icons.verified,
        color: _gold,
        text: l10n.translate('payOwnedEverything'),
      );
    }
    if (ownsThisTier) {
      return _PremiumMessage(
        icon: Icons.verified,
        color: _gold,
        text: l10n.translate('payCurrentPlan'),
      );
    }

    // "Upgrade" rather than "Subscribe" for someone already paying: Play bills
    // them the difference, and calling that a new subscription reads like
    // being charged twice.
    final label = tier == PremiumTier.studio && _controller.isPremiumActive
        ? 'payCtaUpgrade'
        : plan == SubscriptionPlan.lifetime
        ? 'payCtaBuy'
        : 'payCtaSubscribe';

    return _SubscriptionButton(
      label: l10n.translate(label),
      price: product?.localizedPrice,
      loading: _controller.premiumBusy,
      enabled: plan != null && !_controller.premiumBusy,
      onPressed: () {
        if (plan == null) return;
        DuckHaptics.tap();
        _controller.subscribeToPremium(plan);
      },
    );
  }
}

/// One plan, priced.
class _PlanChip extends StatelessWidget {
  const _PlanChip({
    required this.plan,
    required this.product,
    required this.isSelected,
    required this.savingPercent,
    required this.onTap,
  });

  final SubscriptionPlan plan;
  final SubscriptionProduct? product;
  final bool isSelected;
  final int? savingPercent;
  final VoidCallback onTap;

  String get _nameKey => switch (plan) {
    SubscriptionPlan.monthly || SubscriptionPlan.studioMonthly =>
      'payPlanMonthly',
    SubscriptionPlan.yearly || SubscriptionPlan.studioYearly => 'payPlanYearly',
    SubscriptionPlan.lifetime => 'payPlanLifetime',
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: DuckMotion.pressDuration,
        curve: DuckMotion.pressCurve,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? _gold.withValues(alpha: .14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? _gold : _border,
            width: isSelected ? 1.6 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.translate(_nameKey),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isSelected ? _gold : _textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              product?.localizedPrice ?? '—',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _text,
                fontSize: 15,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 4),
            // The saving is worked out from the live prices, so it cannot
            // disagree with the numbers printed right above it.
            if (savingPercent != null)
              Text(
                l10n
                    .translate('paySave')
                    .replaceAll('{percent}', '$savingPercent'),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _green,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                ),
              )
            else if (plan == SubscriptionPlan.lifetime)
              Text(
                l10n.translate('payPlanLifetimeNote'),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              )
            else
              const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _PremiumBenefit extends StatelessWidget {
  const _PremiumBenefit({required this.label, this.highlighted = false});

  final String label;

  /// The one line the higher tier exists for, marked so it does not read as
  /// just another tick in a list of five.
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(
            highlighted ? Icons.auto_awesome : Icons.check_circle,
            color: _gold,
            size: 19,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: highlighted ? _gold : _text,
                fontSize: 14,
                fontWeight: highlighted ? FontWeight.w900 : FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PremiumMessage extends StatelessWidget {
  const _PremiumMessage({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .18)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SubscriptionButton extends StatelessWidget {
  const _SubscriptionButton({
    required this.label,
    required this.price,
    required this.loading,
    required this.enabled,
    required this.onPressed,
  });

  final String label;
  final String? price;
  final bool loading;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: _gold,
          foregroundColor: const Color(0xFF151515),
          disabledBackgroundColor: Colors.white.withValues(alpha: .10),
          disabledForegroundColor: _muted,
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        onPressed: enabled ? onPressed : null,
        child: loading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF151515),
                ),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                  if (price != null) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        price!,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.flow,
    required this.status,
    required this.progress,
  });

  final DuckFlow flow;
  final String status;
  final int progress;

  @override
  Widget build(BuildContext context) {
    if (flow == DuckFlow.idle) return const SizedBox.shrink();

    Widget child;
    if (flow == DuckFlow.extracting) {
      child = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'LOADING..',
            style: TextStyle(
              color: _text,
              fontSize: 14,
              fontWeight: FontWeight.w300,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: 240,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: null,
                minHeight: 2,
                backgroundColor: _isLight ? Colors.black12 : Colors.white10,
                valueColor: AlwaysStoppedAnimation(_gold),
              ),
            ),
          ),
        ],
      );
    } else if (flow == DuckFlow.downloading) {
      // "42% CACHED", not "%42". The sign follows the number in English and in
      // Arabic alike; leading it reads as a formatting bug in both.
      child = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$progress% CACHED',
            style: TextStyle(
              color: _text,
              fontSize: 14,
              fontWeight: FontWeight.w300,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: 240,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: (progress / 100).clamp(0.0, 1.0),
                minHeight: 2,
                backgroundColor: _isLight ? Colors.black12 : Colors.white10,
                valueColor: AlwaysStoppedAnimation(_gold),
              ),
            ),
          ),
        ],
      );
    } else if (flow == DuckFlow.success) {
      child = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'DOWNLOAD COMPLETE',
            style: TextStyle(
              color: _gold,
              fontSize: 14,
              fontWeight: FontWeight.w300,
              letterSpacing: 2,
            ),
          ),
        ],
      );
    } else {
      child = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Text(
          status,
          maxLines: 4,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: _danger,
            fontSize: 13,
            fontWeight: FontWeight.w300,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 280),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: KeyedSubtree(key: ValueKey(flow), child: child),
      ),
    );
  }
}

class _OptionsCard extends StatelessWidget {
  const _OptionsCard({required this.controller});

  final DuckDownloadsController controller;

  @override
  Widget build(BuildContext context) {
    final metadata = controller.metadata!;
    final formats =
        controller.selectedType == DownloadType.video ||
            controller.selectedType == DownloadType.image
        ? metadata.qualities
        : metadata.audioFormats;
    final labels = formats.map((format) => format.label).toSet().toList();
    if (labels.isEmpty) labels.add('Best');
    final selected = labels.contains(controller.quality)
        ? controller.quality
        : labels.first;
    return _Panel(
      padding: const EdgeInsets.all(14),
      child: Column(
        children: [
          Row(
            children: [
              _Thumb(url: metadata.thumbnail, width: 76, height: 58),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      metadata.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _text,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      metadata.platform,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: _muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _Chip(
                      active: controller.selectedType == DownloadType.image,
                      icon: Icons.image,
                      label: 'Image',
                      onTap: () => controller.changeType(DownloadType.image),
                    ),
                    _Chip(
                      active: controller.selectedType == DownloadType.video,
                      icon: Icons.play_arrow,
                      label: 'Video',
                      onTap: () => controller.changeType(DownloadType.video),
                    ),
                    _Chip(
                      active: controller.selectedType == DownloadType.audio,
                      icon: Icons.music_note,
                      label: 'Audio',
                      onTap: () => controller.changeType(DownloadType.audio),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: _dark,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: _border),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: selected,
                      isExpanded: true,
                      dropdownColor: _dark,
                      style: TextStyle(color: _text, fontSize: 13),
                      items: [
                        for (final label in labels)
                          DropdownMenuItem(value: label, child: Text(label)),
                      ],
                      onChanged: (value) {
                        if (value != null) controller.changeQuality(value);
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 11),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: const Color(0xFF151515),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
              onPressed: controller.busy
                  ? null
                  : () {
                      AdService.instance.showInterstitialAd(
                        isPremiumActive: controller.isPremiumActive,
                        onAdClosed: () {
                          controller.startDownload();
                        },
                      );
                    },
              child: Text(
                controller.busy ? 'Please wait...' : 'Download',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BatchOptionsCard extends StatefulWidget {
  const _BatchOptionsCard({required this.controller});
  final DuckDownloadsController controller;

  @override
  State<_BatchOptionsCard> createState() => _BatchOptionsCardState();
}

enum _BatchDownloadMode { image, video, audio, hybrid }

class _BatchOptionsCardState extends State<_BatchOptionsCard> {
  final Set<String> _selectedUrls = {};
  _BatchDownloadMode _selectedMode = _BatchDownloadMode.image;
  final String _selectedQuality = 'Best';

  @override
  void initState() {
    super.initState();
    final items = widget.controller.batchItems ?? const [];
    for (final item in items) {
      _selectedUrls.add(item.url);
    }
    _initMode();
  }

  void _initMode() {
    final items = widget.controller.batchItems ?? const [];
    final hasImages = items.any((item) => !item.isVideo);
    final hasVideos = items.any((item) => item.isVideo);
    if (hasImages && hasVideos) {
      _selectedMode = _BatchDownloadMode.hybrid;
    } else if (widget.controller.selectedType == DownloadType.image) {
      _selectedMode = _BatchDownloadMode.image;
    } else if (widget.controller.selectedType == DownloadType.audio) {
      _selectedMode = _BatchDownloadMode.audio;
    } else {
      _selectedMode = _BatchDownloadMode.video;
    }
  }

  @override
  void didUpdateWidget(_BatchOptionsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller.batchItems != widget.controller.batchItems) {
      _selectedUrls.clear();
      final items = widget.controller.batchItems ?? const [];
      for (final item in items) {
        _selectedUrls.add(item.url);
      }
      _initMode();
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.controller.batchItems ?? const [];
    final title = widget.controller.batchTitle ?? 'Batch Links';
    final hasImages = items.any((item) => !item.isVideo);
    final hasVideos = items.any((item) => item.isVideo);
    final isHybrid = hasImages && hasVideos;

    return _Panel(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _text,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                icon: Icon(Icons.close, color: _textMuted, size: 20),
                onPressed: widget.controller.clearBatch,
              ),
            ],
          ),
          Row(
            children: [
              if (widget.controller.batchPlatform != null) ...[
                Text(
                  widget.controller.batchPlatform!.toUpperCase(),
                  style: TextStyle(
                    color: _gold,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Text(
                '${plural(items.length, 'item')} found',
                style: TextStyle(color: _textMuted, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (isHybrid)
                _Chip(
                  active: _selectedMode == _BatchDownloadMode.hybrid,
                  icon: Icons.layers,
                  label: 'Hybrid',
                  onTap: () =>
                      setState(() => _selectedMode = _BatchDownloadMode.hybrid),
                ),
              _Chip(
                active: _selectedMode == _BatchDownloadMode.image,
                icon: Icons.image,
                label: 'Image',
                onTap: () =>
                    setState(() => _selectedMode = _BatchDownloadMode.image),
              ),
              _Chip(
                active: _selectedMode == _BatchDownloadMode.video,
                icon: Icons.play_arrow,
                label: 'Video',
                onTap: () =>
                    setState(() => _selectedMode = _BatchDownloadMode.video),
              ),
              _Chip(
                active: _selectedMode == _BatchDownloadMode.audio,
                icon: Icons.music_note,
                label: 'Audio',
                onTap: () =>
                    setState(() => _selectedMode = _BatchDownloadMode.audio),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            height: 180,
            decoration: BoxDecoration(
              color: _isLight
                  ? const Color(0xFFF1F1F3)
                  : const Color(0xFF1C1C1E),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _border),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Select items',
                        style: TextStyle(
                          color: _textMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            if (_selectedUrls.length == items.length) {
                              _selectedUrls.clear();
                            } else {
                              _selectedUrls.clear();
                              for (final item in items) {
                                _selectedUrls.add(item.url);
                              }
                            }
                          });
                        },
                        child: Text(
                          _selectedUrls.length == items.length
                              ? 'Deselect All'
                              : 'Select All',
                          style: TextStyle(
                            color: _gold,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: _divider),
                Expanded(
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final isSelected = _selectedUrls.contains(item.url);
                      return CheckboxListTile(
                        value: isSelected,
                        dense: true,
                        activeColor: _gold,
                        checkColor: const Color(0xFF151515),
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 6,
                        ),
                        title: Row(
                          children: [
                            if (item.thumbnail != null &&
                                item.thumbnail!.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(right: 8.0),
                                child: _Thumb(
                                  url: item.thumbnail,
                                  width: 36,
                                  height: 28,
                                ),
                              ),
                            Expanded(
                              child: Text(
                                item.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: _text, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                        onChanged: (val) {
                          setState(() {
                            if (val == true) {
                              _selectedUrls.add(item.url);
                            } else {
                              _selectedUrls.remove(item.url);
                            }
                          });
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: const Color(0xFF151515),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
              onPressed: _selectedUrls.isEmpty || widget.controller.busy
                  ? null
                  : () {
                      AdService.instance.showInterstitialAd(
                        isPremiumActive: widget.controller.isPremiumActive,
                        onAdClosed: () async {
                          final urls = _selectedUrls.toList();
                          DownloadType dlType;
                          if (_selectedMode == _BatchDownloadMode.image) {
                            dlType = DownloadType.image;
                          } else if (_selectedMode ==
                              _BatchDownloadMode.audio) {
                            dlType = DownloadType.audio;
                          } else {
                            dlType = DownloadType.video;
                          }
                          await widget.controller.startBatchDownload(
                            urls: urls,
                            type: dlType,
                            quality: _selectedQuality,
                            forceHybrid:
                                _selectedMode == _BatchDownloadMode.hybrid,
                          );
                          widget.controller.clearBatch();
                        },
                      );
                    },
              child: Text(
                widget.controller.busy
                    ? 'Starting downloads...'
                    : 'Download Selected (${_selectedUrls.length})',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadQueueCard extends StatelessWidget {
  const _DownloadQueueCard({required this.controller, required this.items});

  final DuckDownloadsController controller;
  final List<DownloadItem> items;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      padding: const EdgeInsets.all(13),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 210),
        child: Column(
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Download Queue',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Text(
                  '${items.length}',
                  style: TextStyle(color: _muted, fontWeight: FontWeight.w900),
                ),
              ],
            ),
            const SizedBox(height: 9),
            Expanded(
              child: ListView.separated(
                padding: EdgeInsets.zero,
                itemCount: items.take(4).length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final item = items[index];
                  final pending = controller.controlPendingIds.contains(
                    item.id,
                  );
                  return _QueueRow(
                    controller: controller,
                    item: item,
                    pending: pending,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    required this.controller,
    required this.item,
    required this.pending,
  });

  final DuckDownloadsController controller;
  final DownloadItem item;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final isProcessing = item.status == DownloadStatus.processing;
    final isPaused = item.status == DownloadStatus.paused;
    final disablePause = pending || isProcessing;
    final progressLabel = isProcessing ? 'Processing' : '${item.progress}%';
    final typeLabel = isProcessing ? 'processing' : item.type.name;

    return Opacity(
      opacity: pending ? .72 : 1,
      child: Row(
        children: [
          _Thumb(
            url: item.thumbnail,
            width: 38,
            height: 32,
            icon: item.isImage
                ? Icons.image
                : item.isAudio
                ? Icons.music_note
                : Icons.play_arrow,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: isProcessing
                        ? null
                        : (item.progress / 100).clamp(0.0, 1.0),
                    minHeight: 4,
                    backgroundColor: const Color(0xFF333333),
                    valueColor: AlwaysStoppedAnimation(_gold),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 7),
          SizedBox(
            width: isProcessing ? 76 : 38,
            child: Text(
              progressLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _gold,
                fontSize: 11,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          SizedBox(
            width: isProcessing ? 74 : 38,
            child: Text(
              typeLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _muted,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          _RoundAction(
            icon: disablePause
                ? Icons.more_horiz
                : isPaused
                ? Icons.play_arrow
                : Icons.pause,
            disabled: disablePause,
            onTap: () => isPaused
                ? controller.resumeDownload(item)
                : controller.pauseDownload(item),
          ),
          const SizedBox(width: 4),
          _RoundAction(
            icon: Icons.close,
            danger: true,
            disabled: pending,
            onTap: () => controller.cancelDownload(item),
          ),
        ],
      ),
    );
  }
}

enum _LibrarySubTab { all, folders, favorites, playlists }

class _LibraryView extends StatefulWidget {
  const _LibraryView({
    required this.title,
    required this.items,
    required this.emptyTitle,
    required this.emptyMessage,
    required this.emptyIcon,
    required this.controller,
  });

  final String title;
  final List<DownloadItem> items;
  final String emptyTitle;
  final String emptyMessage;
  final IconData emptyIcon;
  final DuckDownloadsController controller;

  @override
  State<_LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<_LibraryView> {
  _LibrarySubTab _subTab = _LibrarySubTab.all;
  bool _useGridLayout = true;
  Offset? _dragPillOffset;
  bool _isDraggingPill = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addBackInterceptor(_handleBack);
  }

  @override
  void dispose() {
    widget.controller.removeBackInterceptor(_handleBack);
    super.dispose();
  }

  /// Back inside the library steps back out of the sub-tab before it leaves
  /// the tab.
  ///
  /// Landing on Home from three levels deep is the thing that made back feel
  /// arbitrary: the user picked Folders deliberately, and undoing that one
  /// choice is what they mean by "back" — not unwinding the whole screen.
  bool _handleBack() {
    if (_subTab != _LibrarySubTab.all) {
      setState(() => _subTab = _LibrarySubTab.all);
      return true;
    }
    return false;
  }

  bool get _isImagesTab => widget.title == 'IMAGES';

  /// Space the floating nav bar — and the mini player when visible — cover.
  ///
  /// The nav bar pads itself by MediaQuery.paddingOf(context).bottom, so a
  /// fixed number here left the last row of every list sitting underneath it
  /// on any device with a gesture bar or home indicator.
  double get _bottomPadding {
    final hasMiniPlayer =
        widget.controller.playingItem != null &&
        widget.controller.playerItem == null;
    return (hasMiniPlayer ? 150.0 : 80.0) +
        MediaQuery.paddingOf(context).bottom;
  }

  Widget _buildUnifiedSubTabBar() {
    final activeIndex = switch (_subTab) {
      _LibrarySubTab.all => 0,
      _LibrarySubTab.folders => 1,
      _LibrarySubTab.favorites => 2,
      _LibrarySubTab.playlists => 3,
    };

    final isLight = Theme.of(context).brightness == Brightness.light;
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    final effectiveIndex = isRtl ? (3 - activeIndex) : activeIndex;

    final defaultLeft = 4.0 + (effectiveIndex * 78.0);
    final currentLeft = _isDraggingPill ? _dragPillOffset!.dx : defaultLeft;
    final currentTop = _isDraggingPill ? _dragPillOffset!.dy : 4.0;

    final duration = _isDraggingPill
        ? Duration.zero
        : const Duration(milliseconds: 300);
    final curve = _isDraggingPill ? Curves.linear : Curves.easeOutBack;

    final scale = _isDraggingPill ? 1.08 : 1.0;
    final width = _isDraggingPill ? 88.0 : 78.0;
    final leftOffset = _isDraggingPill ? -5.0 : 0.0;

    final isAudios = widget.title == 'AUDIOS';

    return Center(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) {
          final targetLeft = details.localPosition.dx - 39.0;
          final targetTop = details.localPosition.dy - 16.0;
          final minLeft = 4.0;
          final maxLeft = 238.0;
          setState(() {
            _isDraggingPill = true;
            _dragPillOffset = Offset(
              targetLeft.clamp(minLeft, maxLeft),
              targetTop.clamp(0.0, 8.0),
            );
          });
        },
        onPanUpdate: (details) {
          final targetLeft = details.localPosition.dx - 39.0;
          final targetTop = details.localPosition.dy - 16.0;
          final minLeft = 4.0;
          final maxLeft = 238.0;

          double dragLeft = targetLeft;
          if (targetLeft < minLeft) {
            final diff = minLeft - targetLeft;
            dragLeft = minLeft - diff.clamp(0.0, 30.0) * 0.15;
          } else if (targetLeft > maxLeft) {
            final diff = targetLeft - maxLeft;
            dragLeft = maxLeft + diff.clamp(0.0, 30.0) * 0.15;
          }

          double dragTop = targetTop;
          if (targetTop < 4.0) {
            final diff = 4.0 - targetTop;
            dragTop = 4.0 - diff.clamp(0.0, 15.0) * 0.15;
          } else {
            final diff = targetTop - 4.0;
            dragTop = 4.0 + diff.clamp(0.0, 15.0) * 0.15;
          }

          setState(() {
            _dragPillOffset = Offset(dragLeft, dragTop);
          });
        },
        onPanEnd: (details) {
          if (_dragPillOffset != null) {
            final center = _dragPillOffset!.dx + 39.0;
            final rawIndex = ((center - 4.0) / 78.0).round().clamp(0, 3);
            final targetIndex = isRtl ? (3 - rawIndex) : rawIndex;
            setState(() {
              _isDraggingPill = false;
              _subTab = switch (targetIndex) {
                0 => _LibrarySubTab.all,
                1 => _LibrarySubTab.folders,
                2 => _LibrarySubTab.favorites,
                3 => _LibrarySubTab.playlists,
                _ => _LibrarySubTab.all,
              };
            });
          }
        },
          child: Container(
            width: 320,
            height: 42,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(21),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.12),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: DuckLiquidGlassTrack(
                    borderRadius: 21,
                    isLight: isLight,
                    isDragging: _isDraggingPill,
                    blurSigma: 16,
                    fallbackColor: Colors.white.withValues(
                      alpha: isLight ? 0.45 : 0.05,
                    ),
                    fallbackBorderColor: (isLight ? Colors.black : Colors.white)
                        .withValues(alpha: 0.12),
                    child: const SizedBox.expand(),
                  ),
                ),
                AnimatedPositioned(
                  duration: duration,
                  curve: curve,
                  left: currentLeft + leftOffset,
                  top: currentTop,
                  width: width,
                  height: 32.0,
                  child: Transform.scale(
                    scale: scale,
                    child: DuckLiquidGlassPill(
                      width: width,
                      height: 32,
                      borderRadius: 16,
                      goldColor: _gold,
                      isDragging: _isDraggingPill,
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Row(
                    children: [
                      _buildTabOption(
                        _LibrarySubTab.all,
                        isAudios
                            ? AppLocalizations.of(context).translate('songs')
                            : AppLocalizations.of(context).translate('all'),
                        activeIndex == 0,
                      ),
                      _buildTabOption(
                        _LibrarySubTab.folders,
                        AppLocalizations.of(context).translate('folders'),
                        activeIndex == 1,
                      ),
                      _buildTabOption(
                        _LibrarySubTab.favorites,
                        AppLocalizations.of(context).translate('favorites'),
                        activeIndex == 2,
                      ),
                      _buildTabOption(
                        _LibrarySubTab.playlists,
                        AppLocalizations.of(context).translate('playlists'),
                        activeIndex == 3,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

  Widget _buildTabOption(_LibrarySubTab tab, String label, bool active) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _subTab = tab),
        child: Center(
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 200),
            style: TextStyle(
              color: active ? const Color(0xFF101112) : _textMuted,
              fontWeight: FontWeight.bold,
              fontSize: 11,
              letterSpacing: 0.5,
            ),
            child: Text(label),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    List<DownloadItem> filteredItems = [];
    if (_subTab == _LibrarySubTab.all) {
      filteredItems = widget.items;
    } else if (_subTab == _LibrarySubTab.favorites) {
      filteredItems = widget.items.where((item) => item.favorite).toList();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.center,
              child: SizedBox(
                width: MediaQuery.sizeOf(context).width - 32,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      onPressed: () => widget.controller.popTabHistory(),
                      icon: Icon(
                        Icons.arrow_back_ios_new,
                        color: _gold,
                        size: 24,
                      ),
                    ),
                    Expanded(
                      // Shrinks rather than truncates. This row carries a back
                      // button, two icon buttons and the auto-save switch, so
                      // what is left for the title is narrow enough that even
                      // "IMAGES" was rendering as "IMA…" at this letter
                      // spacing. Arabic titles are longer still. A title that
                      // is 2pt smaller reads fine; one that is cut in half
                      // does not.
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.center,
                        child: Text(
                          widget.title,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          style: TextStyle(
                            color: _text,
                            fontSize: 20,
                            letterSpacing: 3,
                            fontWeight: FontWeight.w300,
                          ),
                        ),
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_isImagesTab && _subTab != _LibrarySubTab.playlists)
                          IconButton(
                            icon: Icon(
                              _useGridLayout
                                  ? Icons.view_list
                                  : Icons.grid_view,
                              color: _gold,
                              size: 24,
                            ),
                            tooltip: _useGridLayout ? 'List view' : 'Grid view',
                            onPressed: () => setState(
                              () => _useGridLayout = !_useGridLayout,
                            ),
                          ),
                        IconButton(
                          icon: Icon(
                            Icons.lock_outline,
                            color: _gold,
                            size: 24,
                          ),
                          onPressed: () {
                            final title = widget.title.toUpperCase();
                            final mediaType = title == 'VIDEOS'
                                ? 'video'
                                : (title == 'AUDIOS' ? 'audio' : 'image');
                            _showVaultPinDialog(
                              context,
                              widget.controller,
                              onSuccess: () {
                                Navigator.push(
                                  context,
                                  DuckPageRoute(
                                    builder: (context) => _SecureVaultView(
                                      controller: widget.controller,
                                      mediaType: mediaType,
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
                        const SizedBox(width: 8),
                        _AutoSaveToggleSwitch(controller: widget.controller),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _buildUnifiedSubTabBar(),
          const SizedBox(height: 10),
          Expanded(
            child: _subTab == _LibrarySubTab.folders
                ? _buildFoldersTab()
                : _subTab == _LibrarySubTab.playlists
                ? _buildPlaylistsTab()
                : filteredItems.isEmpty
                ? (_subTab == _LibrarySubTab.favorites
                      ? const DuckEmptyState(
                          icon: Icons.favorite_border_rounded,
                          title: 'No favourites yet',
                          message:
                              'Tap the heart on anything in your library to '
                              'keep it close by.',
                        )
                      : DuckEmptyState(
                          icon: widget.emptyIcon,
                          imageAsset: DuckAssets.duckIdle(),
                          title: widget.emptyTitle,
                          message: widget.emptyMessage,
                          actionLabel: 'Paste a link',
                          onAction: () {
                            widget.controller.setTab(DuckTab.home);
                            widget.controller.pasteAndExtract();
                          },
                        ))
                : _isImagesTab && _useGridLayout
                ? GridView.builder(
                    padding: EdgeInsets.only(bottom: _bottomPadding),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          childAspectRatio: 1,
                        ),
                    itemCount: filteredItems.length,
                    itemBuilder: (context, index) {
                      final item = filteredItems[index];
                      return EntranceFade(
                        index: index,
                        child: Pressable(
                        pressedScale: 0.94,
                        onTap: () => widget.controller.openPlayer(
                          item,
                          galleryItems: filteredItems,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              MediaThumb(
                                url: item.thumbnail,
                                filePath: item.filePath,
                                width: double.infinity,
                                height: double.infinity,
                                radius: 10,
                              ),
                              if (item.favorite)
                                const Positioned(
                                  top: 6,
                                  right: 6,
                                  child: Icon(
                                    Icons.favorite,
                                    color: _danger,
                                    size: 16,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        ),
                      );
                    },
                  )
                : ListView.separated(
                    padding: EdgeInsets.only(bottom: _bottomPadding),
                    itemBuilder: (context, index) => EntranceFade(
                      index: index,
                      child: _DownloadRow(
                        item: filteredItems[index],
                        controller: widget.controller,
                        galleryItems: _isImagesTab ? filteredItems : null,
                        queueItems: widget.title == 'AUDIOS'
                            ? filteredItems
                            : null,
                      ),
                    ),
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: _divider),
                    itemCount: filteredItems.length,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFoldersTab() {
    final title = widget.title.toUpperCase();
    // The library is no longer read at startup, so the first time this tab is
    // built it asks for it. Scheduled after the frame because this runs during
    // build and the load calls notifyListeners.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.ensureDeviceFolders();
    });

    final List<DeviceMediaFolder> folders = title == 'VIDEOS'
        ? widget.controller.videoFolders
        : (title == 'IMAGES'
              ? widget.controller.imageFolders
              : widget.controller.audioFolders);

    if (folders.isEmpty && widget.controller.deviceFoldersLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (folders.isEmpty) {
      // Denied access and genuinely-empty storage look identical on screen but
      // need completely different actions, so they are separated here.
      final denied = widget.controller.deviceMediaAccessDenied;
      return DuckEmptyState(
        icon: denied ? Icons.lock_outline_rounded : Icons.folder_off_outlined,
        title: denied ? 'Media access needed' : 'No $title folders found',
        message: denied
            ? 'Duck needs permission to read your photos, videos and audio to '
                  'browse and manage the folders on this device.'
            : 'Nothing turned up in your device storage. Scan again if you '
                  'have just added files.',
        actionLabel: denied ? 'Grant access' : 'Scan storage',
        onAction: () async {
          await widget.controller.refreshDeviceFolders();
          // A second denial means the OS has stopped showing the prompt, so
          // send the user where they can still change it.
          if (widget.controller.deviceMediaAccessDenied && denied) {
            await widget.controller.openDeviceMediaSettings();
          }
        },
      );
    }

    return GridView.builder(
      padding: EdgeInsets.only(bottom: _bottomPadding),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.1,
      ),
      itemCount: folders.length,
      itemBuilder: (context, index) {
        final folder = folders[index];
        return GestureDetector(
          onTap: () => _showFolderItemsSheet(folder),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.12)),
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Icon(
                      title == 'VIDEOS'
                          ? Icons.folder_zip
                          : (title == 'IMAGES'
                                ? Icons.folder_special
                                : Icons.folder_copy),
                      color: _gold,
                      size: 32,
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: _gold.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        plural(folder.itemCount, 'item'),
                        style: TextStyle(
                          color: _gold,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      folder.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _text,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      folder.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: _textMuted, fontSize: 10),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showFolderItemsSheet(DeviceMediaFolder folder) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DeviceFolderSheet(
        folder: folder,
        controller: widget.controller,
      ),
    );
  }

  Widget _buildPlaylistsTab() {
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: ElevatedButton.icon(
            icon: const Icon(Icons.add, color: Color(0xFF101112), size: 18),
            label: const Text(
              'NEW PLAYLIST',
              style: TextStyle(
                color: Color(0xFF101112),
                fontWeight: FontWeight.w900,
                fontSize: 11,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: _gold,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
            onPressed: () =>
                _showCreatePlaylistDialog(context, widget.controller),
          ),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: widget.controller.playlists.isEmpty
              ? Center(
                  child: Text(
                    'No playlists created yet.',
                    style: TextStyle(color: _muted, fontSize: 16),
                  ),
                )
              : ListView.builder(
                  padding: EdgeInsets.only(bottom: _bottomPadding),
                  itemCount: widget.controller.playlists.length,
                  itemBuilder: (context, index) {
                    final playlist = widget.controller.playlists[index];
                    final playlistItems = widget.controller.downloads
                        .where(
                          (item) =>
                              playlist.downloadIds.contains(item.id) &&
                              item.type ==
                                  (widget.title == 'VIDEOS'
                                      ? DownloadType.video
                                      : DownloadType.audio) &&
                              item.status == DownloadStatus.completed,
                        )
                        .toList();
                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: _panel,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: _border),
                      ),
                      child: ListTile(
                        leading: Icon(
                          Icons.playlist_play,
                          color: _gold,
                          size: 28,
                        ),
                        title: Text(
                          playlist.name,
                          style: TextStyle(
                            color: _text,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: Text(
                          plural(playlistItems.length, 'item'),
                          style: TextStyle(color: _muted),
                        ),
                        trailing: IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            color: _danger,
                          ),
                          onPressed: () =>
                              widget.controller.deletePlaylist(playlist.id),
                        ),
                        onTap: () {
                          Navigator.push(
                            context,
                            DuckPageRoute(
                              builder: (context) => _PlaylistItemsView(
                                playlist: playlist,
                                controller: widget.controller,
                                type: widget.title == 'VIDEOS'
                                    ? DownloadType.video
                                    : DownloadType.audio,
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _DownloadRow extends StatelessWidget {
  const _DownloadRow({
    required this.item,
    required this.controller,
    this.galleryItems,
    this.queueItems,
  });

  final DownloadItem item;
  final DuckDownloadsController controller;
  final List<DownloadItem>? galleryItems;
  final List<DownloadItem>? queueItems;

  String _getFileSize(DownloadItem item) {
    if (item.filePath == null) return '0.0 MB';
    try {
      final file = File(item.filePath!);
      if (file.existsSync()) {
        final bytes = file.lengthSync();
        final mb = bytes / (1024 * 1024);
        return '${mb.toStringAsFixed(1)} MB';
      }
    } catch (_) {}
    return '0.0 MB';
  }

  Widget _buildGridIcon() {
    return Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [_dot(), const SizedBox(width: 4), _dot()],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [_dot(), const SizedBox(width: 4), _dot()],
          ),
        ],
      ),
    );
  }

  Widget _dot() {
    return Container(
      width: 5,
      height: 5,
      decoration: BoxDecoration(color: _gold, shape: BoxShape.circle),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sizeStr = _getFileSize(item);
    final subtitle = item.artist != null && item.artist!.trim().isNotEmpty
        ? '${item.artist!} â€¢ $sizeStr'
        : sizeStr;
    return SizedBox(
      height: 86,
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () => controller.openPlayer(
                item,
                galleryItems: galleryItems,
                queueItems: queueItems,
              ),
              child: Row(
                children: [
                  _Thumb(
                    url: item.thumbnail,
                    filePath: item.filePath,
                    width: 58,
                    height: 66,
                    icon: item.isImage
                        ? Icons.image
                        : item.isAudio
                        ? Icons.music_note
                        : Icons.play_arrow,
                    radius: 8,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _displayName(item),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _text,
                            fontSize: 15,
                            fontWeight: FontWeight.w300,
                          ),
                        ),
                        const SizedBox(height: 7),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _textMuted,
                            fontSize: 13,
                            fontWeight: FontWeight.w300,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (item.savedToGallery || item.savedToMusic)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 8.0),
              child: Icon(Icons.check_circle, color: _gold, size: 20),
            ),
          PopupMenuButton<String>(
            icon: _buildGridIcon(),
            color: _isLight ? const Color(0xFFFFFFFF) : const Color(0xFF18181A),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            onSelected: (value) {
              switch (value) {
                case 'view':
                  controller.openPlayer(
                    item,
                    galleryItems: galleryItems,
                    queueItems: queueItems,
                  );
                case 'share':
                  controller.shareDownload(item);
                case 'rename':
                  _showRenameDialog(context, item, controller);
                case 'save':
                  _handleSaveAction(context, item, controller);
                case 'delete':
                  controller.deleteDownload(item);
                case 'favorite':
                  controller.toggleFavorite(item);
                case 'playlist':
                  _showPlaylistSelectionSheet(context, item, controller);
                case 'vault':
                  if (controller.isVaultLocked) {
                    _showVaultPinDialog(
                      context,
                      controller,
                      onSuccess: () {
                        unawaited(controller.moveItemToVault(item));
                      },
                    );
                  } else {
                    unawaited(controller.moveItemToVault(item));
                  }
                case 'edit_tag':
                  _showMetadataEditDialog(context, item, controller);
                case 'convert_audio':
                  _showVideoToAudioDialog(context, item, controller);
                case 'ringtone':
                  _showRingtoneCutterSheet(context, item, controller);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'save',
                child: Row(
                  children: [
                    Icon(Icons.download, color: _gold, size: 20),
                    const SizedBox(width: 12),
                    Text(
                      _getSaveLabel(item),
                      style: TextStyle(color: _text, fontSize: 14),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'share',
                child: Row(
                  children: [
                    Icon(Icons.share, color: _gold, size: 20),
                    SizedBox(width: 12),
                    Text('Share', style: TextStyle(color: _text, fontSize: 14)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'rename',
                child: Row(
                  children: [
                    Icon(Icons.edit_outlined, color: _gold, size: 20),
                    SizedBox(width: 12),
                    Text(
                      'Rename',
                      style: TextStyle(color: _text, fontSize: 14),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'favorite',
                child: Row(
                  children: [
                    Icon(
                      item.favorite ? Icons.star : Icons.star_border,
                      color: _gold,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      item.favorite ? 'Unfavorite' : 'Favorite',
                      style: TextStyle(color: _text, fontSize: 14),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'playlist',
                child: Row(
                  children: [
                    Icon(Icons.playlist_add, color: _gold, size: 20),
                    SizedBox(width: 12),
                    Text(
                      'Add to Playlist',
                      style: TextStyle(color: _text, fontSize: 14),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'vault',
                child: Row(
                  children: [
                    Icon(Icons.lock_outline, color: _gold, size: 20),
                    SizedBox(width: 12),
                    Text(
                      'Move to Secure Vault',
                      style: TextStyle(color: _text, fontSize: 14),
                    ),
                  ],
                ),
              ),
              if (item.isVideo)
                PopupMenuItem(
                  value: 'convert_audio',
                  child: Row(
                    children: [
                      Icon(Icons.audiotrack, color: _gold, size: 20),
                      const SizedBox(width: 12),
                      Text(
                        'Convert to Audio',
                        style: TextStyle(color: _text, fontSize: 14),
                      ),
                    ],
                  ),
                ),
              if (item.isAudio)
                PopupMenuItem(
                  value: 'edit_tag',
                  child: Row(
                    children: [
                      Icon(Icons.label_outline, color: _gold, size: 20),
                      SizedBox(width: 12),
                      Text(
                        'Edit Tag Info',
                        style: TextStyle(color: _text, fontSize: 14),
                      ),
                    ],
                  ),
                ),
              if (item.isAudio && Platform.isAndroid)
                PopupMenuItem(
                  value: 'ringtone',
                  child: Row(
                    children: [
                      Icon(Icons.ring_volume, color: _gold, size: 20),
                      const SizedBox(width: 12),
                      Text(
                        'Set as Ringtone',
                        style: TextStyle(color: _text, fontSize: 14),
                      ),
                    ],
                  ),
                ),
              const PopupMenuDivider(height: 1),
              PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    const Icon(Icons.delete_outline, color: _danger, size: 20),
                    const SizedBox(width: 12),
                    Text(
                      'Delete',
                      style: TextStyle(
                        color: _danger,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _displayName(DownloadItem item) {
    if (item.isImage) {
      final ext = item.filePath?.split('.').last ?? 'jpg';
      return item.title.toLowerCase().endsWith('.$ext')
          ? item.title
          : '${item.title}.$ext';
    }
    final ext = item.isAudio ? 'mp3' : 'mp4';
    return item.title.toLowerCase().endsWith('.$ext')
        ? item.title
        : '${item.title}.$ext';
  }
}

void _showPlaylistSelectionSheet(
  BuildContext context,
  DownloadItem item,
  DuckDownloadsController controller,
) {
  showModalBottomSheet(
    context: context,
    backgroundColor: _panel,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) {
      return AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Add to Playlist',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      TextButton.icon(
                        icon: Icon(Icons.add, color: _gold),
                        label: Text(
                          'Create New',
                          style: TextStyle(color: _gold),
                        ),
                        onPressed: () {
                          Navigator.pop(context);
                          _showCreatePlaylistDialog(context, controller);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (controller.playlists.isEmpty)
                    Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 32),
                        child: Text(
                          'No playlists created yet.',
                          style: TextStyle(color: _muted),
                        ),
                      ),
                    )
                  else
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(context).height * 0.4,
                      ),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: controller.playlists.length,
                        itemBuilder: (context, index) {
                          final playlist = controller.playlists[index];
                          final contains = playlist.downloadIds.contains(
                            item.id,
                          );
                          return ListTile(
                            leading: Icon(
                              Icons.playlist_play,
                              color: contains ? _gold : _muted,
                            ),
                            title: Text(
                              playlist.name,
                              style: TextStyle(
                                color: contains ? _gold : Colors.white,
                                fontWeight: contains
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                              ),
                            ),
                            trailing: contains
                                ? IconButton(
                                    icon: const Icon(
                                      Icons.remove_circle_outline,
                                      color: _danger,
                                    ),
                                    onPressed: () {
                                      controller.removeDownloadFromPlaylist(
                                        playlist.id,
                                        item.id,
                                      );
                                    },
                                  )
                                : IconButton(
                                    icon: Icon(
                                      Icons.add_circle_outline,
                                      color: _gold,
                                    ),
                                    onPressed: () {
                                      controller.addDownloadToPlaylist(
                                        playlist.id,
                                        item.id,
                                      );
                                    },
                                  ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

void _showCreatePlaylistDialog(
  BuildContext context,
  DuckDownloadsController controller,
) {
  final textController = TextEditingController();
  showDialog(
    context: context,
    builder: (context) {
      return AlertDialog(
        backgroundColor: _panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'New Playlist',
          style: TextStyle(color: Colors.white),
        ),
        content: TextField(
          controller: textController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Enter playlist name',
            hintStyle: TextStyle(color: Colors.white38),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: _gold),
            ),
          ),
        ),
        actions: [
          TextButton(
            child: Text('Cancel', style: TextStyle(color: _muted)),
            onPressed: () => Navigator.pop(context),
          ),
          TextButton(
            child: Text('Create', style: TextStyle(color: _gold)),
            onPressed: () {
              if (textController.text.trim().isNotEmpty) {
                controller.createPlaylist(textController.text);
              }
              Navigator.pop(context);
            },
          ),
        ],
      );
    },
  );
}

void _showVaultPinDialog(
  BuildContext context,
  DuckDownloadsController controller, {
  required VoidCallback onSuccess,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) {
      return _VaultPinSheet(controller: controller, onSuccess: onSuccess);
    },
  );
}

class _VaultPinSheet extends StatefulWidget {
  const _VaultPinSheet({required this.controller, required this.onSuccess});

  final DuckDownloadsController controller;
  final VoidCallback onSuccess;

  @override
  State<_VaultPinSheet> createState() => _VaultPinSheetState();
}

class _VaultPinSheetState extends State<_VaultPinSheet> {
  String _pin = '';
  String _firstPin = '';
  bool _confirmMode = false;
  String _message = '';
  bool _resetMode = false;
  bool _newPinMode = false;
  bool _isCheckingPin = false;

  @override
  void initState() {
    super.initState();
    _message = widget.controller.isVaultSetup
        ? 'Enter your $_pinLength-digit passcode'
        : 'Create a $_pinLength-digit vault passcode';
    if (widget.controller.isVaultSetup && widget.controller.biometricEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _authenticateWithBiometrics();
      });
    }
  }

  Future<void> _authenticateWithBiometrics() async {
    final auth = LocalAuthentication();
    try {
      final canAuthenticateWithBiometrics = await auth.canCheckBiometrics;
      final canAuthenticate =
          canAuthenticateWithBiometrics || await auth.isDeviceSupported();
      if (!canAuthenticate) return;

      final didAuthenticate = await auth.authenticate(
        localizedReason: 'Authenticate to access the Secure Vault',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
      if (didAuthenticate &&
          mounted &&
          await widget.controller.unlockVaultBiometric()) {
        if (!mounted) return;
        Navigator.pop(context);
        widget.onSuccess();
      }
    } catch (_) {}
  }

  void _onKeyPress(String val) {
    if (_isCheckingPin || _pin.length >= _pinLength) return;
    setState(() {
      _pin += val;
      if (_pin.length == _pinLength) _message = 'Checking passcode...';
    });
    if (_pin.length == _pinLength) unawaited(_submitPin());
  }

  Future<void> _submitPin() async {
    if (_isCheckingPin) return;
    setState(() => _isCheckingPin = true);
    try {
      await _handlePinComplete();
    } catch (_) {
      if (mounted) {
        setState(() {
          _pin = '';
          _message = 'Vault error. Please try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _isCheckingPin = false);
    }
  }
  void _onBackspace() {
    if (_pin.isEmpty) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
    });
  }

  void _onResetPress() {
    setState(() {
      _resetMode = true;
      _newPinMode = false;
      _confirmMode = false;
      _pin = '';
      _message = 'Enter current passcode to reset';
    });
  }

  Future<void> _handlePinComplete() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (!mounted) return;

    if (_resetMode) {
      final correct = await widget.controller.checkVaultPin(_pin);
      if (correct) {
        setState(() {
          _resetMode = false;
          _newPinMode = true;
          _confirmMode = false;
          _pin = '';
          _message = 'Create a new $_pinLength-digit passcode';
        });
      } else {
        setState(() {
          _pin = '';
          _message = 'Incorrect passcode. Try again.';
        });
      }
      return;
    }

    if (_newPinMode || !widget.controller.isVaultSetup) {
      if (!_confirmMode) {
        setState(() {
          _firstPin = _pin;
          _pin = '';
          _confirmMode = true;
          _message = 'Confirm your vault passcode';
        });
      } else if (_pin == _firstPin) {
        await widget.controller.setVaultPin(_pin);
        if (!mounted) return;
        Navigator.pop(context);
        widget.onSuccess();
      } else {
        setState(() {
          _pin = '';
          _confirmMode = false;
          _message = 'Passcodes do not match. Try again.';
        });
      }
      return;
    }

    final correct = await widget.controller.checkVaultPin(_pin);
    if (!mounted) return;
    if (correct) {
      Navigator.pop(context);
      widget.onSuccess();
    } else {
      setState(() {
        _pin = '';
        _message = 'Incorrect passcode. Try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _dark,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        gradient: RadialGradient(
          center: const Alignment(0, -0.4),
          radius: 1.0,
          colors: [const Color(0x1CFFC52F), _dark],
        ),
      ),
      padding: const EdgeInsets.all(24),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 5,
                decoration: BoxDecoration(
                  color: _border,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              const SizedBox(height: 28),
              Icon(Icons.lock_outline, color: _gold, size: 40),
              const SizedBox(height: 16),
              Text(
                'Secure Vault',
                style: TextStyle(
                  color: _text,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(_message, style: TextStyle(color: _muted, fontSize: 14)),
              const SizedBox(height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_pinLength, (index) {
                  final filled = index < _pin.length;
                  return Container(
                    width: 16,
                    height: 16,
                    margin: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: filled ? _gold : Colors.transparent,
                      border: Border.all(color: _gold, width: 2),
                    ),
                  );
                }),
              ),
              if (widget.controller.isVaultSetup &&
                  widget.controller.biometricEnabled) ...[
                const SizedBox(height: 12),
                IconButton(
                  icon: Icon(Icons.fingerprint, color: _gold, size: 40),
                  onPressed: _authenticateWithBiometrics,
                ),
              ],
              const SizedBox(height: 32),
              _buildKeypad(),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildKeypad() {
    final keys = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      [widget.controller.isVaultSetup ? 'Reset' : 'C', '0', '⌫'],
    ];
    return Column(
      children: keys.map((row) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: row.map((val) {
            final isAction = val == 'C' || val == 'Reset' || val == '⌫';
            return Container(
              width: 72,
              height: 72,
              margin: const EdgeInsets.symmetric(vertical: 8),
              child: ClipOval(
                child: Material(
                  color: isAction ? Colors.transparent : _panel,
                  child: InkWell(
                    onTap: () {
                      if (val == 'C') {
                        setState(() => _pin = '');
                      } else if (val == 'Reset') {
                        _onResetPress();
                      } else if (val == '⌫') {
                        _onBackspace();
                      } else {
                        _onKeyPress(val);
                      }
                    },
                    child: Center(
                      child: val == '⌫'
                          ? Icon(
                              Icons.backspace_outlined,
                              color: _text,
                              size: 22,
                            )
                          : val == 'Reset'
                          ? Icon(Icons.lock_reset, color: _text, size: 26)
                          : Text(
                              val,
                              style: TextStyle(
                                color: isAction ? _muted : _text,
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        );
      }).toList(),
    );
  }
}

class _SecureVaultView extends StatefulWidget {
  const _SecureVaultView({required this.controller, required this.mediaType});

  final DuckDownloadsController controller;
  final String mediaType; // 'audio' | 'video' | 'image'

  @override
  State<_SecureVaultView> createState() => _SecureVaultViewState();
}

class _SecureVaultViewState extends State<_SecureVaultView> {
  /// Whether names and thumbnails are legible right now.
  ///
  /// The vault's whole promise is that what is inside it is nobody else's
  /// business, and a list of readable filenames breaks that promise before a
  /// single file is opened: a glance over a shoulder, a screen mirrored to a
  /// TV, or a screenshot taken by another app all leak the contents without
  /// ever touching the encryption.
  ///
  /// Android cannot blur part of a captured screenshot, so this blurs the UI
  /// itself. Peeking is a deliberate act, and it resets when the screen is
  /// left, because a vault that stays unblurred is one the user forgets to
  /// re-hide.
  bool _revealed = false;

  Future<void> _onBackRequested(BuildContext context) async {
    // No confirmation. Leaving the vault destroys nothing and takes one tap to
    // undo, so a dialog on every exit was pure friction: the user answers it
    // the same way every time, which is the definition of a prompt that should
    // not be there.
    widget.controller.closePlayer();
    await widget.controller.audioPlayer.stop();
    widget.controller.lockVault();

    // Deliberately no setTab(DuckTab.home) here. Sending the user to Home threw
    // away where they were: open the vault from VIDEOS, come back, and you are
    // somewhere else. Popping the route returns them to the tab that opened it,
    // which is what every other screen in the app now does.
    if (context.mounted) Navigator.pop(context);
  }

  void _showVaultSettings(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            color: _dark,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: _border),
          ),
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 48,
                height: 5,
                decoration: BoxDecoration(
                  color: _border,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Vault Settings',
                style: TextStyle(
                  color: _text,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              StatefulBuilder(
                builder: (context, setModalState) => SwitchListTile(
                  title: Text(
                    'Biometric Unlock',
                    style: TextStyle(color: _text),
                  ),
                  subtitle: Text(
                    'Unlock the vault using fingerprint / Face ID',
                    style: TextStyle(color: _muted),
                  ),
                  value: widget.controller.biometricEnabled,
                  activeColor: _gold,
                  onChanged: (val) async {
                    await widget.controller.toggleBiometricEnabled(val);
                    setModalState(() {});
                  },
                ),
              ),
              const Divider(color: Colors.white10),
              ListTile(
                leading: const Icon(Icons.security, color: _danger),
                title: Text(
                  'Set Decoy Passcode',
                  style: TextStyle(color: _text),
                ),
                subtitle: Text(
                  'Shows a decoy empty vault when entered',
                  style: TextStyle(color: _muted),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _showSetDecoyPinDialog(context);
                },
              ),
              const Divider(color: Colors.white10),
              ListTile(
                leading: Icon(Icons.photo_camera, color: _warmGold),
                title: Text(
                  'View Intruder Logs',
                  style: TextStyle(color: _text),
                ),
                subtitle: Text(
                  'Photos captured on failed passcode attempts',
                  style: TextStyle(color: _muted),
                ),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    DuckPageRoute(
                      builder: (context) => const _IntruderLogsScreen(),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showSetDecoyPinDialog(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return _DecoyPinSetupSheet(controller: widget.controller);
      },
    );
  }

  Future<void> _importLocalMedia(BuildContext context) async {
    try {
      FileType fileType;
      DownloadType downloadType;

      if (widget.mediaType == 'audio') {
        fileType = FileType.audio;
        downloadType = DownloadType.audio;
      } else if (widget.mediaType == 'video') {
        fileType = FileType.video;
        downloadType = DownloadType.video;
      } else {
        fileType = FileType.image;
        downloadType = DownloadType.image;
      }

      final result = await FilePicker.platform.pickFiles(
        type: fileType,
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        final path = result.files.single.path!;

        if (context.mounted) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) =>
                Center(child: CircularProgressIndicator(color: _gold)),
          );
        }

        await widget.controller.importLocalFileToVault(path, downloadType);

        if (context.mounted) {
          Navigator.pop(context); // Close loading indicator
          _showSettingToast(
            context,
            'Media added to vault and removed from gallery!',
            true,
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context); // Close loading indicator if open
        _showSettingToast(context, 'Import failed: $e', false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _onBackRequested(context);
      },
      child: Scaffold(
        backgroundColor: _dark,
        appBar: AppBar(
          backgroundColor: _nav,
          title: Text(
            widget.mediaType == 'audio'
                ? 'AUDIO VAULT'
                : widget.mediaType == 'video'
                ? 'VIDEO VAULT'
                : 'IMAGE VAULT',
            style: TextStyle(
              color: _gold,
              fontWeight: FontWeight.w900,
              fontSize: 18,
              letterSpacing: 2,
            ),
          ),
          centerTitle: true,
          leading: IconButton(
            icon: Icon(Icons.arrow_back_ios_new, color: _text),
            onPressed: () => _onBackRequested(context),
          ),
          actions: [
            // Tapping a row plays the file, so revealing cannot live there.
            // One control for the whole list is also the honest shape: what is
            // being hidden is the list, not any single row of it.
            IconButton(
              tooltip: _revealed ? 'Hide names' : 'Show names',
              onPressed: () {
                widget.controller.touchVault();
                setState(() => _revealed = !_revealed);
              },
              icon: Icon(
                _revealed
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                color: _gold,
              ),
            ),
            if (!widget.controller.isDecoySession)
              IconButton(
                icon: Icon(Icons.settings, color: _text),
                onPressed: () => _showVaultSettings(context),
              ),
          ],
        ),
        floatingActionButton: FloatingActionButton(
          backgroundColor: _gold,
          onPressed: () => _importLocalMedia(context),
          child: const Icon(Icons.add, color: Colors.black, size: 28),
        ),
        body: AnimatedBuilder(
          animation: widget.controller,
          builder: (context, _) {
            final items = widget.controller.privateDownloads.where((item) {
              if (widget.mediaType == 'audio') return item.isAudio;
              if (widget.mediaType == 'video') return item.isVideo;
              if (widget.mediaType == 'image') return item.isImage;
              return false;
            }).toList();

            if (items.isEmpty) {
              return Center(
                child: Text(
                  'No private files in vault.',
                  style: TextStyle(color: _muted),
                ),
              );
            } else {
              return NotificationListener<ScrollNotification>(
                // Scrolling the list is use, not idleness. Without this the
                // countdown would run out while the user was still browsing.
                onNotification: (_) {
                  widget.controller.touchVault();
                  return false;
                },
                child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  return _VaultItemTile(
                    item: item,
                    controller: widget.controller,
                    revealed: _revealed,
                  );
                },
                ),
              );
            }
          },
        ),
      ),
    );
  }
}

class _DecoyPinSetupSheet extends StatefulWidget {
  const _DecoyPinSetupSheet({required this.controller});

  final DuckDownloadsController controller;

  @override
  State<_DecoyPinSetupSheet> createState() => _DecoyPinSetupSheetState();
}

class _DecoyPinSetupSheetState extends State<_DecoyPinSetupSheet> {
  String _pin = '';
  String _firstPin = '';
  bool _confirmMode = false;
  String _message = 'Create a $_pinLength-digit decoy passcode';

  void _onKeyPress(String val) {
    if (_pin.length >= _pinLength) return;
    setState(() {
      _pin += val;
      if (_pin.length == _pinLength) _handlePinComplete();
    });
  }
  void _onBackspace() {
    if (_pin.isEmpty) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
    });
  }

  void _handlePinComplete() {
    Future.delayed(const Duration(milliseconds: 200), () {
      if (!mounted) return;

      if (!_confirmMode) {
        setState(() {
          _firstPin = _pin;
          _pin = '';
          _confirmMode = true;
          _message = 'Confirm decoy passcode';
        });
      } else {
        if (_pin == _firstPin) {
          widget.controller.setDecoyVaultPin(_pin);
          Navigator.pop(context);
          _showSettingToast(
            context,
            'Decoy passcode configured successfully!',
            true,
          );
        } else {
          setState(() {
            _pin = '';
            _confirmMode = false;
            _message = 'Passcodes do not match. Try again.';
          });
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _dark,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        border: Border.all(color: _border),
      ),
      padding: const EdgeInsets.all(24),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 5,
              decoration: BoxDecoration(
                color: _border,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            const SizedBox(height: 28),
            const Icon(Icons.security, color: _danger, size: 40),
            const SizedBox(height: 16),
            Text(
              'Set Decoy Passcode',
              style: TextStyle(
                color: _text,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(_message, style: TextStyle(color: _muted, fontSize: 14)),
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_pinLength, (index) {
                final filled = index < _pin.length;
                return Container(
                  width: 16,
                  height: 16,
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: filled ? _danger : Colors.transparent,
                    border: Border.all(color: _danger, width: 2),
                  ),
                );
              }),
            ),
            const SizedBox(height: 32),
            _buildKeypad(),
          ],
        ),
      ),
    );
  }

  Widget _buildKeypad() {
    final keys = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['C', '0', '⌫'],
    ];
    return Column(
      children: keys.map((row) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: row.map((val) {
            final isAction = val == 'C' || val == '⌫';
            return Container(
              width: 72,
              height: 72,
              margin: const EdgeInsets.symmetric(vertical: 8),
              child: ClipOval(
                child: Material(
                  color: isAction ? Colors.transparent : _panel,
                  child: InkWell(
                    onTap: () {
                      if (val == 'C') {
                        setState(() => _pin = '');
                      } else if (val == '⌫') {
                        _onBackspace();
                      } else {
                        _onKeyPress(val);
                      }
                    },
                    child: Center(
                      child: val == '⌫'
                          ? Icon(
                              Icons.backspace_outlined,
                              color: _text,
                              size: 22,
                            )
                          : Text(
                              val,
                              style: TextStyle(
                                color: isAction ? _muted : _text,
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        );
      }).toList(),
    );
  }
}

class _IntruderLogsScreen extends StatefulWidget {
  const _IntruderLogsScreen();

  @override
  State<_IntruderLogsScreen> createState() => _IntruderLogsScreenState();
}

class _IntruderLogsScreenState extends State<_IntruderLogsScreen> {
  List<File> _logs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    final logs = await VaultCameraService.getIntruderLogs();
    setState(() {
      _logs = logs;
      _loading = false;
    });
  }

  Future<void> _clearLogs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _dark,
        title: Text(
          'Clear Logs?',
          style: TextStyle(color: _text, fontWeight: FontWeight.bold),
        ),
        content: Text(
          'Are you sure you want to delete all intruder logs?',
          style: TextStyle(color: _muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel', style: TextStyle(color: _muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Delete All',
              style: TextStyle(color: _danger, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await VaultCameraService.clearIntruderLogs();
      await _loadLogs();
      if (mounted) {
        _showSettingToast(context, 'Intruder logs cleared!', true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _dark,
      appBar: AppBar(
        backgroundColor: _nav,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new, color: _text),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'INTRUDER LOGS',
          style: TextStyle(
            color: _gold,
            fontWeight: FontWeight.w900,
            fontSize: 16,
            letterSpacing: 2,
          ),
        ),
        centerTitle: true,
        actions: [
          if (_logs.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep, color: _danger),
              onPressed: _clearLogs,
            ),
        ],
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: _gold))
          : _logs.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.check_circle_outline, color: _muted, size: 64),
                  const SizedBox(height: 16),
                  Text(
                    'No intrusion attempts logged.',
                    style: TextStyle(color: _muted, fontSize: 16),
                  ),
                ],
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                childAspectRatio: 0.75,
              ),
              itemCount: _logs.length,
              itemBuilder: (context, index) {
                final file = _logs[index];
                final filename = p.basename(file.path);
                final timestampStr = filename
                    .replaceAll('intruder_', '')
                    .replaceAll('.jpg', '');
                final timestamp = int.tryParse(timestampStr) ?? 0;
                final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
                final dateFormatted =
                    '${date.day}/${date.month}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

                return Container(
                  decoration: BoxDecoration(
                    color: _panel,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: _border),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Image.file(
                          file,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              const Center(child: Icon(Icons.broken_image)),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Text(
                          dateFormatted,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _text,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

class _VaultItemTile extends StatelessWidget {
  const _VaultItemTile({
    required this.item,
    required this.controller,
    this.revealed = true,
  });

  final DownloadItem item;
  final DuckDownloadsController controller;

  /// False while the vault is hiding what it holds.
  final bool revealed;

  /// Blurs its child until the vault is peeked at.
  ///
  /// A blur rather than a placeholder block on purpose: the row keeps its real
  /// shape and length, so the list still reads as a list and the user can
  /// still find the file they are looking for by position. A row of grey bars
  /// would hide the same information and lose that.
  Widget _veil(Widget child, {double sigma = 6}) {
    if (revealed) return child;
    return ImageFiltered(
      imageFilter: ImageFilter.blur(
        sigmaX: sigma,
        sigmaY: sigma,
        // Without this the blur samples transparent pixels past the edge and
        // the text fades out at its ends instead of staying evenly obscured.
        tileMode: TileMode.decal,
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Row(
        children: [
          _veil(
            _Thumb(
              url: item.thumbnail,
              filePath: item.filePath,
              width: 48,
              height: 48,
              icon: item.isAudio ? Icons.music_note : Icons.play_arrow,
            ),
            sigma: 8,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _veil(
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: _text, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  item.platform,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.play_circle_outline, color: _gold),
            onPressed: () {
              final vaultImages = controller.privateDownloads
                  .where((entry) => entry.isImage)
                  .toList();
              controller.openPlayer(
                item,
                galleryItems: item.isImage ? vaultImages : null,
                queueItems: item.isAudio
                    ? controller.privateDownloads
                          .where((entry) => entry.isAudio)
                          .toList()
                    : null,
              );
            },
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, color: _muted),
            color: _isLight ? Colors.white : const Color(0xFF202124),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            onSelected: (value) async {
              if (value == 'restore') {
                await controller.moveItemFromVault(item);
              } else if (value == 'delete') {
                await controller.deleteDownload(item);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'restore',
                child: Text(
                  'Restore to Library',
                  style: TextStyle(color: _text, fontWeight: FontWeight.w500),
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'delete',
                child: Text(
                  'Delete Permanent',
                  style: TextStyle(
                    color: const Color(0xFFE53935),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PlaylistItemsView extends StatelessWidget {
  const _PlaylistItemsView({
    required this.playlist,
    required this.controller,
    required this.type,
  });

  final Playlist playlist;
  final DuckDownloadsController controller;
  final DownloadType type;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _dark,
      appBar: AppBar(
        backgroundColor: _nav,
        title: Text(
          playlist.name.toUpperCase(),
          style: TextStyle(
            color: _gold,
            fontWeight: FontWeight.w900,
            fontSize: 18,
            letterSpacing: 2,
          ),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new, color: _text),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final currentPlaylist = controller.playlists.firstWhere(
            (p) => p.id == playlist.id,
            orElse: () => playlist,
          );
          final items = controller.downloads
              .where(
                (item) =>
                    currentPlaylist.downloadIds.contains(item.id) &&
                    item.type == type &&
                    item.status == DownloadStatus.completed,
              )
              .toList();

          if (items.isEmpty) {
            return Center(
              child: Text(
                'No completed items in this playlist.',
                style: TextStyle(color: _muted),
              ),
            );
          } else {
            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemBuilder: (context, index) {
                final item = items[index];
                return Container(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: () => controller.openPlayer(
                            item,
                            galleryItems: type == DownloadType.image
                                ? items
                                : null,
                            queueItems: type == DownloadType.audio
                                ? items
                                : null,
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 50,
                                height: 50,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: _border),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: item.isImage
                                      ? Image.file(
                                          File(item.filePath!),
                                          fit: BoxFit.cover,
                                        )
                                      : Icon(
                                          item.isAudio
                                              ? Icons.audiotrack
                                              : Icons.videocam,
                                          color: _gold,
                                        ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  item.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: _text, fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.remove_circle_outline,
                          color: _danger,
                        ),
                        onPressed: () {
                          controller.removeDownloadFromPlaylist(
                            currentPlaylist.id,
                            item.id,
                          );
                        },
                      ),
                    ],
                  ),
                );
              },
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, color: Color(0xFFBFBFBF)),
              itemCount: items.length,
            );
          }
        },
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, required this.padding});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(padding: padding, child: child);
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.active,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final bool active;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: active ? _gold : _dark,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: active ? _gold : _border),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 17,
              color: active ? const Color(0xFF151515) : _text,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: active ? const Color(0xFF151515) : _text,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.url,
    required this.width,
    required this.height,
    this.filePath,
    this.icon = Icons.image,
    this.radius = 8,
  });

  final String? url;
  final String? filePath;
  final double width;
  final double height;
  final IconData icon;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return MediaThumb(
      url: url,
      filePath: filePath,
      width: width,
      height: height,
      icon: icon,
      radius: radius,
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.onTap,
    this.danger = false,
    this.disabled = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool danger;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: disabled ? null : onTap,
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: (danger ? _danger : _gold).withValues(alpha: .14),
        ),
        child: Icon(icon, color: danger ? _danger : _gold, size: 16),
      ),
    );
  }
}

String _getSaveLabel(DownloadItem item) {
  if (item.isImage) {
    return Platform.isIOS ? 'Save to Photos' : 'Save to Pictures';
  }
  if (item.isVideo) {
    return Platform.isIOS ? 'Save to Photos' : 'Save to Gallery';
  }
  if (Platform.isIOS) {
    return 'Save to Files';
  } else if (Platform.isAndroid) {
    return 'Save to Music';
  } else {
    return 'Save audio';
  }
}

class _ClipboardDetectorOverlay extends StatelessWidget {
  const _ClipboardDetectorOverlay({
    required this.url,
    required this.onDismiss,
    required this.onAccept,
  });

  final String url;
  final VoidCallback onDismiss;
  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: .5),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxWidth: 480),
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: const Color(0x1F2A2A2D),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: _gold.withValues(alpha: .16),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .3),
                        blurRadius: 32,
                        offset: const Offset(0, 16),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 58,
                        height: 58,
                        decoration: BoxDecoration(
                          color: _gold.withValues(alpha: .12),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.link, color: _gold, size: 28),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        AppLocalizations.of(context).translate('linkDetectedClipboard'),
                        style: TextStyle(
                          color: _text,
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        url,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: _textMuted, fontSize: 14),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: _textMuted,
                                side: BorderSide(color: _border),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              onPressed: onDismiss,
                              child: Text(
                                AppLocalizations.of(context).translate('dismiss'),
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: _gold,
                                foregroundColor: const Color(0xFF151515),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              onPressed: onAccept,
                              child: Text(
                                AppLocalizations.of(context).translate('downloadNow'),
                                style: const TextStyle(fontWeight: FontWeight.w900),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickShareOverlay extends StatelessWidget {
  const _QuickShareOverlay({
    required this.url,
    required this.controller,
    required this.onDismiss,
    required this.onAcceptFormat,
    required this.onAcceptDefault,
  });

  final String url;
  final DuckDownloadsController controller;
  final VoidCallback onDismiss;
  final Function(FormatInfo, DownloadType) onAcceptFormat;
  final Function(DownloadType) onAcceptDefault;

  @override
  Widget build(BuildContext context) {
    final videoQualities = controller.quickShareVideoQualities;
    final audioQualities = controller.quickShareAudioQualities;
    final isExtracting = controller.isQuickShareExtracting;

    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: .6),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                child: Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxWidth: 480),
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: const Color(0x1F2A2A2D),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: _gold.withValues(alpha: .3),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .4),
                        blurRadius: 32,
                        offset: const Offset(0, 16),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: _gold.withValues(alpha: .15),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(Icons.bolt, color: _gold, size: 24),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Duck Quick Download',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: _text,
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: Icon(Icons.close, color: _textMuted),
                            onPressed: onDismiss,
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: _gold, fontSize: 12),
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (isExtracting) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    _gold,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                'Analyzing available qualities...',
                                style: TextStyle(
                                  color: _textMuted,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ] else if (videoQualities.isNotEmpty ||
                          audioQualities.isNotEmpty) ...[
                        Text(
                          'Select Video Quality:',
                          style: TextStyle(
                            color: _textMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: videoQualities.map((q) {
                            return ChoiceChip(
                              label: Text(q.label),
                              selected: false,
                              selectedColor: _gold,
                              backgroundColor: Colors.white.withOpacity(0.08),
                              labelStyle: TextStyle(
                                color: _gold,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                              onSelected: (_) =>
                                  onAcceptFormat(q, DownloadType.video),
                            );
                          }).toList(),
                        ),
                        if (audioQualities.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Select Audio Quality:',
                            style: TextStyle(
                              color: _textMuted,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: audioQualities.map((q) {
                              return ChoiceChip(
                                label: Text('MP3 (${q.label})'),
                                selected: false,
                                selectedColor: _gold,
                                backgroundColor: Colors.white.withOpacity(0.08),
                                labelStyle: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                                onSelected: (_) =>
                                    onAcceptFormat(q, DownloadType.audio),
                              );
                            }).toList(),
                          ),
                        ],
                      ] else ...[
                        Text(
                          AppLocalizations.of(context).translate('selectFormat'),
                          style: TextStyle(
                            color: _textMuted,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _gold,
                                  foregroundColor: const Color(0xFF101112),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                onPressed: () =>
                                    onAcceptDefault(DownloadType.video),
                                icon: const Icon(Icons.movie, size: 20),
                                label: Text(
                                  AppLocalizations.of(context).translate('videoHD'),
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  side: BorderSide(
                                    color: _gold.withOpacity(0.6),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                onPressed: () =>
                                    onAcceptDefault(DownloadType.audio),
                                icon: Icon(
                                  Icons.music_note,
                                  color: _gold,
                                  size: 20,
                                ),
                                label: Text(
                                  AppLocalizations.of(context).translate('audioMP3'),
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: TextButton.icon(
                          onPressed: () => onAcceptDefault(DownloadType.image),
                          icon: Icon(Icons.image, color: _textMuted, size: 18),
                          label: Text(
                            AppLocalizations.of(context).translate('images'),
                            style: TextStyle(color: _textMuted, fontSize: 13),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void _showMetadataEditDialog(
  BuildContext context,
  DownloadItem item,
  DuckDownloadsController controller,
) {
  final titleController = TextEditingController(text: item.title);
  final artistController = TextEditingController(text: item.artist ?? '');
  final albumController = TextEditingController(text: item.album ?? '');

  showDialog<void>(
    context: context,
    builder: (context) {
      return AlertDialog(
        backgroundColor: _panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Edit Audio Tags',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Title',
                  labelStyle: TextStyle(color: _muted),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: _gold),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: artistController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Artist',
                  labelStyle: TextStyle(color: _muted),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: _gold),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: albumController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Album',
                  labelStyle: TextStyle(color: _muted),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: _gold),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white70),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _gold,
              foregroundColor: const Color(0xFF151515),
            ),
            onPressed: () async {
              final newTitle = titleController.text.trim();
              if (newTitle.isEmpty) return;
              Navigator.pop(context);
              try {
                await controller.updateItemMetadata(
                  item,
                  title: newTitle,
                  artist: artistController.text.trim(),
                  album: albumController.text.trim(),
                );
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Failed to update tags: $e'),
                      backgroundColor: _danger,
                    ),
                  );
                }
              }
            },
            child: const Text('Save'),
          ),
        ],
      );
    },
  );
}

Future<bool> _checkAndRequestStoragePermission(
  BuildContext context,
  DownloadType type,
) async {
  final permissions = PermissionService();
  bool hasPerm = false;

  if (type == DownloadType.image) {
    hasPerm = await permissions.hasMediaImagesPermission();
  } else {
    // For video/audio on Android 10+, Scoped Storage/MediaStore is used which does not need storage permissions
    if (Platform.isAndroid) {
      return true;
    }
    hasPerm = await permissions.hasStoragePermission();
  }

  if (hasPerm) return true;

  if (context.mounted) {
    final granted = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF18181A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Row(
            children: [
              Icon(Icons.security, color: Color(0xFFFFD700), size: 24),
              SizedBox(width: 10),
              Text(
                'Permission Required',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          content: Text(
            type == DownloadType.image
                ? 'Duck Downloader needs Photos/Storage permission to save images directly to your gallery.'
                : 'Duck Downloader needs Storage permission to save files directly to your device storage.',
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white54),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text(
                'Grant',
                style: TextStyle(
                  color: Color(0xFFFFD700),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );

    if (granted == true) {
      if (type == DownloadType.image) {
        return await permissions.requestMediaImagesPermission();
      } else {
        return await permissions.requestStoragePermission();
      }
    }
  }
  return false;
}

void _handleSaveAction(
  BuildContext context,
  DownloadItem item,
  DuckDownloadsController controller,
) async {
  final hasPerm = await _checkAndRequestStoragePermission(context, item.type);
  if (!hasPerm) {
    if (context.mounted) {
      _showSettingToast(
        context,
        'Permission denied. Cannot save media.',
        false,
      );
    }
    return;
  }

  if (item.isImage) {
    controller.saveImageExternally(item);
  } else if (item.isVideo) {
    controller.saveVideoExternally(item);
  } else {
    controller.saveAudioExternally(item);
  }
}

void _showRenameDialog(
  BuildContext context,
  DownloadItem item,
  DuckDownloadsController controller,
) {
  final textController = TextEditingController(text: item.title);
  showDialog<void>(
    context: context,
    builder: (context) {
      return AlertDialog(
        backgroundColor: _panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        title: const Text(
          'Rename',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: textController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Colors.white24),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: _gold),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white54),
            ),
          ),
          TextButton(
            onPressed: () async {
              final newTitle = textController.text.trim();
              if (newTitle.isNotEmpty) {
                await controller.updateItemMetadata(
                  item,
                  title: newTitle,
                  artist: item.artist ?? '',
                  album: item.album ?? '',
                );
              }
              if (context.mounted) Navigator.pop(context);
            },
            child: Text('Rename', style: TextStyle(color: _gold)),
          ),
        ],
      );
    },
  );
}

void _showVideoToAudioDialog(
  BuildContext context,
  DownloadItem item,
  DuckDownloadsController controller,
) {
  String selectedFormat = 'mp3';
  int selectedBitrate = 192; // Default 192kbps

  showDialog<void>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            backgroundColor: _panel,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(15),
            ),
            title: Text(
              'Convert Video to Audio',
              style: TextStyle(
                color: _text,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _muted, fontSize: 13),
                ),
                const SizedBox(height: 20),
                Text(
                  'Format',
                  style: TextStyle(
                    color: _text,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(
                            color: selectedFormat == 'mp3'
                                ? _gold
                                : Colors.white24,
                          ),
                          backgroundColor: selectedFormat == 'mp3'
                              ? _gold.withOpacity(0.1)
                              : Colors.transparent,
                        ),
                        onPressed: () => setState(() => selectedFormat = 'mp3'),
                        child: Text(
                          'MP3 (Standard)',
                          style: TextStyle(
                            color: selectedFormat == 'mp3' ? _gold : _text,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(
                            color: selectedFormat == 'm4a'
                                ? _gold
                                : Colors.white24,
                          ),
                          backgroundColor: selectedFormat == 'm4a'
                              ? _gold.withOpacity(0.1)
                              : Colors.transparent,
                        ),
                        onPressed: () => setState(() => selectedFormat = 'm4a'),
                        child: Text(
                          'M4A (AAC)',
                          style: TextStyle(
                            color: selectedFormat == 'm4a' ? _gold : _text,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  'Audio Bitrate (Quality)',
                  style: TextStyle(
                    color: _text,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<int>(
                  value: selectedBitrate,
                  dropdownColor: _panel,
                  style: TextStyle(color: _text),
                  decoration: InputDecoration(
                    enabledBorder: OutlineInputBorder(
                      borderSide: const BorderSide(color: Colors.white24),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: _gold),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  items: const [
                    DropdownMenuItem(value: 128, child: Text('128 kbps (Low)')),
                    DropdownMenuItem(
                      value: 192,
                      child: Text('192 kbps (Medium)'),
                    ),
                    DropdownMenuItem(
                      value: 320,
                      child: Text('320 kbps (High/HD)'),
                    ),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      setState(() => selectedBitrate = val);
                    }
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('Cancel', style: TextStyle(color: _muted)),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  _showSettingToast(
                    context,
                    'Audio extraction started in background...',
                    true,
                  );
                  unawaited(
                    controller.convertVideoToAudio(
                      item,
                      selectedFormat,
                      selectedBitrate,
                    ),
                  );
                },
                child: Text(
                  'Convert',
                  style: TextStyle(color: _gold, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          );
        },
      );
    },
  );
}

class _AutoSaveToggleSwitch extends StatefulWidget {
  const _AutoSaveToggleSwitch({required this.controller});
  final DuckDownloadsController controller;

  @override
  State<_AutoSaveToggleSwitch> createState() => _AutoSaveToggleSwitchState();
}

class _AutoSaveToggleSwitchState extends State<_AutoSaveToggleSwitch> {
  Offset? _dragPillOffset;
  bool _isDraggingPill = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.controller.autoSaveVideos;
    final activeIndex = active ? 0 : 1;

    final defaultLeft = 3.0 + (activeIndex * 50.0);
    final currentLeft = _isDraggingPill ? _dragPillOffset!.dx : defaultLeft;
    final currentTop = _isDraggingPill ? _dragPillOffset!.dy : 3.0;

    final duration = _isDraggingPill
        ? Duration.zero
        : const Duration(milliseconds: 240);
    final curve = _isDraggingPill ? Curves.linear : Curves.easeOutBack;

    final scale = _isDraggingPill ? 1.08 : 1.0;
    final width = _isDraggingPill ? 56.0 : 50.0;
    final leftOffset = _isDraggingPill ? -3.0 : 0.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) {
            final targetLeft = details.localPosition.dx - 25.0;
            final targetTop = details.localPosition.dy - 13.0;
            final minLeft = 3.0;
            final maxLeft = 53.0;
            setState(() {
              _isDraggingPill = true;
              _dragPillOffset = Offset(
                targetLeft.clamp(minLeft, maxLeft),
                targetTop.clamp(0.0, 6.0),
              );
            });
          },
          onPanUpdate: (details) {
            final targetLeft = details.localPosition.dx - 25.0;
            final targetTop = details.localPosition.dy - 13.0;
            final minLeft = 3.0;
            final maxLeft = 53.0;

            double dragLeft = targetLeft;
            if (targetLeft < minLeft) {
              final diff = minLeft - targetLeft;
              dragLeft = minLeft - diff.clamp(0.0, 15.0) * 0.15;
            } else if (targetLeft > maxLeft) {
              final diff = targetLeft - maxLeft;
              dragLeft = maxLeft + diff.clamp(0.0, 15.0) * 0.15;
            }

            double dragTop = targetTop;
            if (targetTop < 3.0) {
              final diff = 3.0 - targetTop;
              dragTop = 3.0 - diff.clamp(0.0, 10.0) * 0.15;
            } else {
              final diff = targetTop - 3.0;
              dragTop = 3.0 + diff.clamp(0.0, 10.0) * 0.15;
            }

            setState(() {
              _dragPillOffset = Offset(dragLeft, dragTop);
            });
          },
          onPanEnd: (details) {
            if (_dragPillOffset != null) {
              final center = _dragPillOffset!.dx + 25.0;
              final targetIndex = ((center - 3.0) / 50.0).round().clamp(0, 1);
              setState(() {
                _isDraggingPill = false;
              });
              final newActive = targetIndex == 0;
              if (widget.controller.autoSaveVideos != newActive) {
                widget.controller.toggleAutoSaveVideos(newActive);
                _showSettingToast(
                  context,
                  newActive ? 'Auto Save Enabled' : 'Auto Save Disabled',
                  newActive,
                );
              }
            }
          },
          child: Container(
            width: 106,
            height: 32,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.12),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // 1. Frosted Glass Container Background (Clipped)
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.12),
                            width: 1,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // 2. Sliding Active Pill (NOT Clipped, floats on top!)
                AnimatedPositioned(
                  duration: duration,
                  curve: curve,
                  left: currentLeft + leftOffset,
                  top: currentTop,
                  width: width,
                  height: 26.0,
                  child: Transform.scale(
                    scale: scale,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(13),
                        color: _gold,
                        boxShadow: [
                          BoxShadow(
                            color: _gold.withOpacity(
                              _isDraggingPill ? 0.5 : 0.3,
                            ),
                            blurRadius: _isDraggingPill ? 10 : 6,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // 3. Labels Row
                Positioned.fill(
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            if (!widget.controller.autoSaveVideos) {
                              widget.controller.toggleAutoSaveVideos(true);
                              _showSettingToast(
                                context,
                                'Auto Save Enabled',
                                true,
                              );
                            }
                          },
                          child: Center(
                            child: AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 180),
                              style: TextStyle(
                                color: active
                                    ? const Color(0xFF101112)
                                    : Colors.white60,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                              child: const Text('ON'),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            if (widget.controller.autoSaveVideos) {
                              widget.controller.toggleAutoSaveVideos(false);
                              _showSettingToast(
                                context,
                                'Auto Save Disabled',
                                false,
                              );
                            }
                          },
                          child: Center(
                            child: AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 180),
                              style: TextStyle(
                                color: !active
                                    ? const Color(0xFF101112)
                                    : Colors.white60,
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                              ),
                              child: const Text('OFF'),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Auto save',
          style: TextStyle(color: Colors.white70, fontSize: 11),
        ),
      ],
    );
  }
}

class DottedCircleIcon extends StatelessWidget {
  const DottedCircleIcon({super.key, required this.color, this.size = 24});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _DottedCirclePainter(color: color)),
    );
  }
}

class _DottedCirclePainter extends CustomPainter {
  _DottedCirclePainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    const outerCount = 16;
    for (int i = 0; i < outerCount; i++) {
      final angle = (i * 2 * pi) / outerCount;
      final x = center.dx + radius * 0.9 * cos(angle);
      final y = center.dy + radius * 0.9 * sin(angle);
      canvas.drawCircle(Offset(x, y), 1.8, paint);
    }

    const innerCount = 8;
    for (int i = 0; i < innerCount; i++) {
      final angle = (i * 2 * pi) / innerCount;
      final x = center.dx + radius * 0.5 * cos(angle);
      final y = center.dy + radius * 0.5 * sin(angle);
      canvas.drawCircle(Offset(x, y), 1.8, paint);
    }

    canvas.drawCircle(center, 2.0, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _LibraryButton extends StatefulWidget {
  const _LibraryButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_LibraryButton> createState() => _LibraryButtonState();
}

class _LibraryButtonState extends State<_LibraryButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.92 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DottedCircleIcon(color: _gold, size: 36),
              const SizedBox(height: 8),
              Text(
                widget.label,
                style: TextStyle(
                  color: _gold,
                  fontSize: 11,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomNavBar extends StatefulWidget {
  const _BottomNavBar({required this.controller});
  final DuckDownloadsController controller;

  @override
  State<_BottomNavBar> createState() => _BottomNavBarState();
}

class _BottomNavBarState extends State<_BottomNavBar> {
  Offset? _dragPillOffset;
  bool _isDraggingPill = false;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final goldColor = isLight
        ? const Color(0xFFC69214)
        : const Color(0xFFFFC52F);

    // iOS iPhone layout with 4 tabs and liquid glass support
    final screenWidth = MediaQuery.sizeOf(context).width;
    final totalWidth = screenWidth - 40.0;
    final tabWidth = totalWidth / 4.0;

    final activeIndex = switch (widget.controller.tab) {
      DuckTab.home => 0,
      DuckTab.images => 1,
      DuckTab.videos => 2,
      DuckTab.audios => 3,
    };

    final isRtl = Directionality.of(context) == TextDirection.rtl;
    final effectiveIndex = isRtl ? (3 - activeIndex) : activeIndex;

    final defaultLeft = 4.0 + (effectiveIndex * tabWidth);
    final currentLeft = _isDraggingPill ? _dragPillOffset!.dx : defaultLeft;
    final currentTop = _isDraggingPill ? _dragPillOffset!.dy : 4.0;

    final useLiquidGlass = DuckLiquidGlass.shouldUseLiquidGlass(context);

    final duration = _isDraggingPill
        ? Duration.zero
        : const Duration(milliseconds: 300);
    final curve = _isDraggingPill
        ? Curves.linear
        : (useLiquidGlass ? Curves.easeOutBack : Curves.easeInOut);

    final scale = _isDraggingPill && useLiquidGlass ? 1.05 : 1.0;
    final pillWidth = _isDraggingPill && useLiquidGlass
        ? (tabWidth * 1.08) - 8.0
        : tabWidth - 8.0;
    final leftOffset = _isDraggingPill && useLiquidGlass
        ? -((tabWidth * 0.08) / 2.0)
        : 0.0;

    return Padding(
      padding: EdgeInsets.only(
        bottom: 12 + MediaQuery.paddingOf(context).bottom,
        left: 20,
        right: 20,
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) {
          final targetLeft = details.localPosition.dx - (tabWidth / 2.0);
          final targetTop = details.localPosition.dy - 20.0;
          final minLeft = 4.0;
          final maxLeft = totalWidth - tabWidth + 4.0;
          setState(() {
            _isDraggingPill = true;
            _dragPillOffset = Offset(
              targetLeft.clamp(minLeft, maxLeft),
              targetTop.clamp(0.0, 8.0),
            );
          });
        },
        onPanUpdate: (details) {
          final targetLeft = details.localPosition.dx - (tabWidth / 2.0);
          final targetTop = details.localPosition.dy - 20.0;
          final minLeft = 4.0;
          final maxLeft = totalWidth - tabWidth + 4.0;

          double dragLeft = targetLeft;
          if (targetLeft < minLeft) {
            final diff = minLeft - targetLeft;
            dragLeft = minLeft - diff.clamp(0.0, 30.0) * 0.15;
          } else if (targetLeft > maxLeft) {
            final diff = targetLeft - maxLeft;
            dragLeft = maxLeft + diff.clamp(0.0, 30.0) * 0.15;
          }

          double dragTop = targetTop;
          if (targetTop < 4.0) {
            final diff = 4.0 - targetTop;
            dragTop = 4.0 - diff.clamp(0.0, 15.0) * 0.15;
          } else {
            final diff = targetTop - 4.0;
            dragTop = 4.0 + diff.clamp(0.0, 15.0) * 0.15;
          }

          setState(() {
            _dragPillOffset = Offset(dragLeft, dragTop);
          });
        },
        onPanEnd: (details) {
          if (_dragPillOffset != null) {
            final center = _dragPillOffset!.dx + (tabWidth / 2.0);
            final rawIndex = (center / tabWidth).floor().clamp(0, 3);
            final targetIndex = isRtl ? (3 - rawIndex) : rawIndex;
            setState(() {
              _isDraggingPill = false;
            });
            final targetTab = switch (targetIndex) {
              0 => DuckTab.home,
              1 => DuckTab.images,
              2 => DuckTab.videos,
              3 => DuckTab.audios,
              _ => DuckTab.home,
            };
            widget.controller.setTab(targetTab);
          }
        },
        child: Container(
          width: totalWidth,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.24),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: DuckLiquidGlassTrack(
                  borderRadius: 28,
                  isLight: isLight,
                  isDragging: _isDraggingPill,
                  blurSigma: 18,
                  fallbackColor: isLight
                      ? Colors.white.withValues(alpha: 0.82)
                      : Colors.white.withValues(alpha: 0.06),
                  fallbackBorderColor: goldColor.withValues(
                    alpha: isLight ? 0.12 : 0.16,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
              AnimatedPositioned(
                duration: duration,
                curve: curve,
                left: currentLeft + leftOffset,
                top: currentTop,
                width: pillWidth,
                height: 40.0,
                child: Transform.scale(
                  scale: scale,
                  child: DuckLiquidGlassPill(
                    width: pillWidth,
                    height: 40,
                    borderRadius: 24,
                    goldColor: goldColor,
                    isDragging: _isDraggingPill,
                  ),
                ),
              ),
              // 3. Row of Labels
              SizedBox(
                height: 48,
                child: Row(
                  children: [
                    _buildIOSTabOption(0, 'HOME', activeIndex == 0, isLight),
                    _buildIOSTabOption(1, 'IMAGES', activeIndex == 1, isLight),
                    _buildIOSTabOption(2, 'VIDEOS', activeIndex == 2, isLight),
                    _buildIOSTabOption(3, 'AUDIOS', activeIndex == 3, isLight),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIOSTabOption(
    int index,
    String label,
    bool active,
    bool isLight,
  ) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          final targetTab = switch (index) {
            0 => DuckTab.home,
            1 => DuckTab.images,
            2 => DuckTab.videos,
            3 => DuckTab.audios,
            _ => DuckTab.home,
          };
          widget.controller.setTab(targetTab);
        },
        child: Center(
          child: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 200),
            style: TextStyle(
              color: active
                  ? const Color(0xFF101112)
                  : (isLight ? Colors.black54 : Colors.white60),
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
            child: Text(label),
          ),
        ),
      ),
    );
  }
}

class _PlaylistChoiceOverlay extends StatelessWidget {
  const _PlaylistChoiceOverlay({required this.controller});

  final DuckDownloadsController controller;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final gold = isLight ? const Color(0xFFC69214) : const Color(0xFFFFC52F);
    final dark = isLight ? const Color(0xFFF0F1F2) : const Color(0xFF101112);
    final text = isLight ? const Color(0xFF101112) : Colors.white;
    final textMuted = isLight
        ? const Color(0xFF707172)
        : const Color(0xFF888A8C);

    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.65),
        alignment: Alignment.center,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.4),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: DuckLiquidGlassSurface(
              borderRadius: 20,
              blurSigma: 25,
              variant: DuckLiquidGlassVariant.panel,
              fallbackGradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withOpacity(0.12),
                  Colors.white.withOpacity(0.02),
                ],
              ),
              fallbackBorderColor: Colors.white.withOpacity(0.18),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.playlist_play, color: gold, size: 28),
                            const SizedBox(width: 8),
                            Text(
                              AppLocalizations.of(context).translate('playlistDetected'),
                              style: TextStyle(
                                color: text,
                                fontSize: 16,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ],
                        ),
                        IconButton(
                          icon: Icon(Icons.close, color: textMuted, size: 20),
                          onPressed: () =>
                              controller.resolvePlaylistChoice(false),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      AppLocalizations.of(context).translate('downloadLinkNow'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: text,
                        fontSize: 14,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                    const SizedBox(height: 22),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: dark,
                              foregroundColor: gold,
                              surfaceTintColor: Colors.transparent,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(color: gold.withOpacity(0.5)),
                              ),
                            ),
                            onPressed: () =>
                                controller.resolvePlaylistChoice(false),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.play_circle_outline, size: 24),
                                const SizedBox(height: 4),
                                Text(
                                  AppLocalizations.of(context).translate('downloadSingle'),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: gold,
                              foregroundColor: dark,
                              surfaceTintColor: Colors.transparent,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: () =>
                                controller.resolvePlaylistChoice(true),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.playlist_add, size: 24),
                                const SizedBox(height: 4),
                                Text(
                                  AppLocalizations.of(context).translate('downloadFullPlaylist'),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void _showRingtoneCutterSheet(
  BuildContext context,
  DownloadItem item,
  DuckDownloadsController controller,
) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) {
      return _RingtoneCutterSheet(item: item, controller: controller);
    },
  );
}

class _RingtoneCutterSheet extends StatefulWidget {
  const _RingtoneCutterSheet({required this.item, required this.controller});

  final DownloadItem item;
  final DuckDownloadsController controller;

  @override
  State<_RingtoneCutterSheet> createState() => _RingtoneCutterSheetState();
}

class _RingtoneCutterSheetState extends State<_RingtoneCutterSheet> {
  late final AudioPlayer _previewPlayer;
  double _durationSec = 0.0;
  double _startSec = 0.0;
  double _endSec = 0.0;
  bool _initialized = false;
  bool _isPlaying = false;
  StreamSubscription? _posSub;
  StreamSubscription? _stateSub;

  @override
  void initState() {
    super.initState();
    _previewPlayer = AudioPlayer();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      final filePath = widget.item.filePath;
      if (filePath == null) return;

      final info = await widget.controller.getEffectivePathAndFileName(
        widget.item,
      );
      final actualPath = info['path']!;

      final duration =
          await _previewPlayer.setFilePath(actualPath) ?? Duration.zero;
      if (mounted) {
        setState(() {
          _durationSec = duration.inMilliseconds / 1000.0;
          _endSec = _durationSec > 30.0 ? 30.0 : _durationSec;
          _initialized = true;
        });
      }

      _posSub = _previewPlayer.positionStream.listen((pos) {
        final posSec = pos.inMilliseconds / 1000.0;
        if (_isPlaying && posSec >= _endSec) {
          _previewPlayer.pause();
          _previewPlayer.seek(
            Duration(milliseconds: (_startSec * 1000).toInt()),
          );
        }
      });

      _stateSub = _previewPlayer.playerStateStream.listen((state) {
        if (mounted) {
          setState(() {
            _isPlaying = state.playing;
          });
        }
      });
    } catch (e) {
      debugPrint("Error initializing ringtone preview player: $e");
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _stateSub?.cancel();
    _previewPlayer.dispose();
    super.dispose();
  }

  void _togglePlay() {
    if (!_initialized) return;
    if (_isPlaying) {
      _previewPlayer.pause();
    } else {
      _previewPlayer.seek(Duration(milliseconds: (_startSec * 1000).toInt()));
      _previewPlayer.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final gold = isLight ? const Color(0xFFC69214) : const Color(0xFFFFC52F);
    final dark = isLight ? const Color(0xFFF0F1F2) : const Color(0xFF101112);
    final text = isLight ? const Color(0xFF101112) : Colors.white;
    final textMuted = isLight
        ? const Color(0xFF707172)
        : const Color(0xFF888A8C);

    final selectedDur = _endSec - _startSec;

    return Container(
      decoration: BoxDecoration(
        color: dark,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 20,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        20 + MediaQuery.paddingOf(context).bottom,
      ),
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final isBusy = widget.controller.busy;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: textMuted.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Icon(Icons.ring_volume, color: gold, size: 24),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Ringtone Cutter',
                      style: TextStyle(
                        color: text,
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: textMuted),
                    onPressed: isBusy ? null : () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                widget.item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: textMuted, fontSize: 13),
              ),
              const SizedBox(height: 24),
              if (!_initialized)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: CircularProgressIndicator(),
                  ),
                )
              else ...[
                Text(
                  'Start: ${_startSec.toStringAsFixed(1)}s   |   End: ${_endSec.toStringAsFixed(1)}s',
                  style: TextStyle(
                    color: text,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Duration: ${selectedDur.toStringAsFixed(1)}s (Max 30s)',
                  style: TextStyle(
                    color: selectedDur > 30.05 ? Colors.red : gold,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 16),
                RangeSlider(
                  values: RangeValues(_startSec, _endSec),
                  min: 0.0,
                  max: _durationSec,
                  activeColor: gold,
                  inactiveColor: textMuted.withOpacity(0.2),
                  labels: RangeLabels(
                    '${_startSec.toStringAsFixed(1)}s',
                    '${_endSec.toStringAsFixed(1)}s',
                  ),
                  onChanged: isBusy
                      ? null
                      : (RangeValues values) {
                          double newStart = values.start;
                          double newEnd = values.end;
                          if (newEnd - newStart > 30.0) {
                            if (newStart != _startSec) {
                              newEnd = newStart + 30.0;
                            } else {
                              newStart = newEnd - 30.0;
                            }
                          }
                          setState(() {
                            _startSec = newStart;
                            _endSec = newEnd;
                          });
                          _previewPlayer.seek(
                            Duration(milliseconds: (_startSec * 1000).toInt()),
                          );
                        },
                ),
                const SizedBox(height: 20),
                IconButton(
                  iconSize: 48,
                  icon: Icon(
                    _isPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled,
                    color: gold,
                  ),
                  onPressed: isBusy ? null : _togglePlay,
                ),
                const SizedBox(height: 24),
                if (isBusy) ...[
                  const CircularProgressIndicator(),
                  const SizedBox(height: 10),
                  Text(
                    widget.controller.status,
                    style: TextStyle(color: text, fontSize: 13),
                  ),
                ] else
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: gold,
                        foregroundColor: dark,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: const Icon(Icons.ring_volume),
                      label: const Text(
                        'Set as Default Ringtone',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      onPressed: () async {
                        try {
                          await _previewPlayer.stop();
                          await widget.controller.cutAndSetAsRingtone(
                            widget.item,
                            startTime: _startSec,
                            endTime: _endSec,
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Ringtone updated successfully!'),
                              ),
                            );
                            Navigator.pop(context);
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Error: ${e.toString()}')),
                            );
                          }
                        }
                      },
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}
