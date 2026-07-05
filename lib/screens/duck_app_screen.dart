import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';

import '../models/browser_image_candidate.dart';
import '../models/download_models.dart';
import '../services/premium_entitlement.dart';
import '../state/downloads_controller.dart';
import 'locked_social_browser_screen.dart';

bool get _isLight => PlatformDispatcher.instance.platformBrightness == Brightness.light;

Color get _gold => _isLight ? const Color(0xFFC69214) : const Color(0xFFFFC52F);
Color get _warmGold => _isLight ? const Color(0xFFB58032) : const Color(0xFFF6BD6A);
Color get _dark => _isLight ? const Color(0xFFF5F6F8) : const Color(0xFF101112);
Color get _nav => _isLight ? const Color(0xFFFFFFFF) : const Color(0xFF171819);
Color get _panel => _isLight ? const Color(0xFFFFFFFF) : const Color(0xFF1D1D1F);
Color get _muted => _isLight ? const Color(0xFF6F707A) : const Color(0xFFB8B8B8);
Color get _text => _isLight ? const Color(0xFF151517) : const Color(0xFFFFFFFF);
Color get _textMuted => _isLight ? const Color(0xFF5A5A62) : const Color(0xFFB8B8B8);
Color get _border => _isLight ? Colors.black.withValues(alpha: 0.08) : Colors.white.withValues(alpha: 0.08);
Color get _divider => _isLight ? Colors.black.withValues(alpha: 0.06) : Colors.white.withValues(alpha: 0.08);
const _danger = Color(0xFFFF7A65);
const _green = Color(0xFF41D27D);

class DuckAppScreen extends StatelessWidget {
  const DuckAppScreen({super.key, required this.controller});

  final DuckDownloadsController controller;

  Future<void> _openLockedBrowser(
    BuildContext context,
    LockedBrowserRequest request,
  ) async {
    if (controller.lockedBrowserRequest != request) return;
    controller.clearLockedBrowserRequest();
    final candidates = await Navigator.of(context)
        .push<List<BrowserImageCandidate>>(
          MaterialPageRoute(
            builder: (_) => LockedSocialBrowserScreen(
              initialUrl: request.url,
              platform: request.platform,
              controller: controller,
            ),
          ),
        );
    if (!context.mounted || candidates == null || candidates.isEmpty) return;
    await controller.startBrowserImageDownloads(
      candidates: candidates,
      platform: request.platform,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final browserRequest = controller.lockedBrowserRequest;
        if (browserRequest != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) {
              unawaited(_openLockedBrowser(context, browserRequest));
            }
          });
        }

        final canPop =
            controller.playerItem == null &&
            controller.detectedClipboardUrl == null &&
            controller.tab == DuckTab.home &&
            controller.tabHistory.isEmpty;

        return PopScope(
          canPop: canPop,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;

            // 1. If player is open, close it
            if (controller.playerItem != null) {
              controller.closePlayer();
              return;
            }

            // 2. If clipboard overlay is open, dismiss it
            if (controller.detectedClipboardUrl != null) {
              controller.dismissClipboardDetection();
              return;
            }

            // 3. Otherwise pop tab history
            controller.popTabHistory();
          },
          child: Scaffold(
            backgroundColor: _dark,
            body: Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _dark,
                      gradient: RadialGradient(
                        center: Alignment(0, -0.18),
                        radius: .78,
                        colors: [Color(0x241F1A05), _dark],
                      ),
                    ),
                    child: Padding(
                      padding: EdgeInsets.only(
                        top: MediaQuery.paddingOf(context).top,
                        bottom: controller.playingItem != null &&
                                controller.playerItem == null
                            ? 80
                            : 0,
                      ),
                      child: _bodyForTab(context),
                    ),
                  ),
                ),
                if (controller.playingItem != null &&
                    controller.playerItem == null)
                  Positioned(
                    bottom: 16 + MediaQuery.paddingOf(context).bottom,
                    left: 16,
                    right: 16,
                    child: _MiniPlayer(controller: controller),
                  ),
                if (controller.detectedClipboardUrl != null)
                  _ClipboardDetectorOverlay(
                    url: controller.detectedClipboardUrl!,
                    onDismiss: controller.dismissClipboardDetection,
                    onAccept: controller.acceptClipboardDetection,
                  ),
                if (controller.playerItem != null)
                  (controller.playerItem!.isImage
                      ? _ImageViewerOverlay(
                          item: controller.playerItem!,
                          controller: controller,
                        )
                      : _PlayerOverlay(
                          item: controller.playerItem!,
                          controller: controller,
                        )),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _bodyForTab(BuildContext context) {
    return switch (controller.tab) {
      DuckTab.home => _HomeView(controller: controller),
      DuckTab.images => _LibraryView(
        title: 'IMAGES',
        items: controller.images,
        empty: 'No downloaded images yet.',
        controller: controller,
      ),
      DuckTab.videos => _LibraryView(
        title: 'VIDEOS',
        items: controller.videos,
        empty: 'No downloaded videos yet.',
        controller: controller,
      ),
      DuckTab.audios => _LibraryView(
        title: 'AUDIOS',
        items: controller.audios,
        empty: 'No downloaded audios yet.',
        controller: controller,
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
            padding: EdgeInsets.fromLTRB(28, showQueue ? 14 : 22, 28, 130 * scale),
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
                      _ProBadge(controller: controller),
                    ],
                  ),
                ),
                SizedBox(height: (showQueue ? 8 : 12) * scale),
                _Brand(compact: showQueue, scale: scale),
                SizedBox(height: (showQueue ? 16 : 26) * scale),
                _DuckButton(
                  flow: controller.flow,
                  compact: showQueue,
                  scale: scale,
                  onTap: controller.pasteAndExtract,
                ),
                if (controller.flow == DuckFlow.idle || controller.flow == DuckFlow.ready) ...[
                  const SizedBox(height: 12),
                  IconButton(
                    onPressed: controller.pasteAndExtract,
                    icon: Icon(
                      Icons.ios_share,
                      color: _gold,
                      size: 28,
                    ),
                  ),
                ],
                _StatusBar(
                  flow: controller.flow,
                  status: controller.status,
                  progress: active?.progress ?? 0,
                ),
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
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            padding: EdgeInsets.only(
              bottom: 16 + MediaQuery.paddingOf(context).bottom,
              top: 16,
            ),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  _dark.withValues(alpha: 0.0),
                  _dark.withValues(alpha: 0.8),
                  _dark,
                ],
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _LibraryButton(
                  label: 'IMAGES',
                  onTap: () => controller.setTab(DuckTab.images),
                ),
                _LibraryButton(
                  label: 'VIDEOS',
                  onTap: () => controller.setTab(DuckTab.videos),
                ),
                _LibraryButton(
                  label: 'AUDIOS',
                  onTap: () => controller.setTab(DuckTab.audios),
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
        Text(
          'DUCK DOWNLOADER',
          style: TextStyle(
            color: _text,
            fontSize: (compact ? 22 : 26) * scale,
            letterSpacing: 6,
            fontWeight: FontWeight.w300,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'DOWNLOADER',
          style: TextStyle(
            color: const Color(0xFF8A8A8F),
            fontSize: (compact ? 10 : 12) * scale,
            letterSpacing: 8,
            fontWeight: FontWeight.w300,
          ),
        ),
      ],
    );
  }
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
      onTap: () => controller.toggleAutoSaveVideos(!controller.autoSaveVideos),
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
      onTap: () => controller.toggleEnableClipboardDetection(
        !controller.enableClipboardDetection,
      ),
    );
  }
}

class _HeaderToggle extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? _green.withValues(alpha: .14)
              : Colors.white.withValues(alpha: .07),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active
                ? _green.withValues(alpha: .34)
                : Colors.white.withValues(alpha: .08),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: active ? _green : _muted, size: 17),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                color: active
                    ? const Color(0xFFEAF8EE)
                    : const Color(0xFFE8E8E8),
                fontSize: 12,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProBadge extends StatelessWidget {
  const _ProBadge({required this.controller});

  final DuckDownloadsController controller;

  @override
  Widget build(BuildContext context) {
    final active = controller.isPremiumActive;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => _showPremiumSheet(context, controller),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: active
              ? _gold.withValues(alpha: .18)
              : Colors.white.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active
                ? _gold.withValues(alpha: .42)
                : Colors.white.withValues(alpha: .08),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              active
                  ? Icons.workspace_premium
                  : Icons.workspace_premium_outlined,
              color: active ? _gold : _muted,
              size: 18,
            ),
            const SizedBox(width: 7),
            Text(
              active ? 'PREMIUM' : 'DUCK PREMIUM',
              style: TextStyle(
                color: active ? _gold : const Color(0xFFE8E8E8),
                fontSize: 12,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void _showPremiumSheet(
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

class _PremiumSheet extends StatelessWidget {
  const _PremiumSheet({required this.controller});

  final DuckDownloadsController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final monthly = controller.subscriptionProduct(
          SubscriptionPlan.monthly,
        );
        final yearly = controller.subscriptionProduct(SubscriptionPlan.yearly);
        final musicPremium = controller.subscriptionProduct(
          SubscriptionPlan.musicPremium,
        );
        final busy = controller.premiumBusy;
        final active = controller.isPremiumActive;
        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          child: Container(
            width: double.infinity,
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .86,
            ),
            decoration: BoxDecoration(
              color: const Color(0xFF151617),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withValues(alpha: .08)),
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
                padding: const EdgeInsets.all(18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: _gold.withValues(alpha: .16),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(
                            Icons.workspace_premium,
                            color: _gold,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Duck Premium',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              Text(
                                active
                                    ? 'Your subscription is active.'
                                    : 'Subscribe through the app store.',
                                style: TextStyle(
                                  color: _muted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: Icon(Icons.close, color: _muted),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    const _PremiumBenefit(label: 'Ad-Free Experience'),
                    const _PremiumBenefit(label: 'Faster Processing'),
                    const _PremiumBenefit(label: 'Priority Features'),
                    const _PremiumBenefit(label: 'Future Premium Tools'),
                    const _PremiumBenefit(
                      label: 'Early Access To New Features',
                    ),
                    const _PremiumBenefit(
                      label: 'AI Music Removal (Music Premium)',
                    ),
                    const SizedBox(height: 18),
                    if (controller.premiumError != null)
                      _PremiumMessage(
                        icon: Icons.error_outline,
                        color: _danger,
                        text: controller.premiumError!,
                      )
                    else
                      _PremiumMessage(
                        icon: active ? Icons.verified : Icons.info_outline,
                        color: active ? _gold : _muted,
                        text: controller.premiumStatus,
                      ),
                    const SizedBox(height: 16),
                    _SubscriptionButton(
                      label: 'Subscribe Monthly',
                      price: monthly?.localizedPrice,
                      loading: busy,
                      enabled: monthly != null && !busy,
                      onPressed: () => controller.subscribeToPremium(
                        SubscriptionPlan.monthly,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _SubscriptionButton(
                      label: 'Subscribe Yearly',
                      price: yearly?.localizedPrice,
                      loading: busy,
                      enabled: yearly != null && !busy,
                      onPressed: () => controller.subscribeToPremium(
                        SubscriptionPlan.yearly,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _SubscriptionButton(
                      label: 'Subscribe Music Premium',
                      price: musicPremium?.localizedPrice,
                      loading: busy,
                      enabled: musicPremium != null && !busy,
                      onPressed: () => controller.subscribeToPremium(
                        SubscriptionPlan.musicPremium,
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(
                            color: Colors.white.withValues(alpha: .16),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        onPressed: busy ? null : controller.restorePurchases,
                        icon: busy
                            ? SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: _gold,
                                ),
                              )
                            : const Icon(Icons.restore, size: 18),
                        label: const Text('Restore Purchases'),
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
}

class _PremiumBenefit extends StatelessWidget {
  const _PremiumBenefit({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(Icons.check_circle, color: _gold, size: 19),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFFEDEDED),
                fontSize: 14,
                fontWeight: FontWeight.w700,
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

class _DuckButton extends StatelessWidget {
  const _DuckButton({
    required this.flow,
    required this.compact,
    required this.scale,
    required this.onTap,
  });

  final DuckFlow flow;
  final bool compact;
  final double scale;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Tap duck',
      child: InkWell(
        borderRadius: BorderRadius.circular(180),
        onTap: onTap,
        child: SizedBox(
          width: 360 * scale,
          height: (compact ? 178 : 250) * scale,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned(
                bottom: (compact ? 20 : 30) * scale,
                child: Container(
                  width: (compact ? 230 : 300) * scale,
                  height: (compact ? 72 : 92) * scale,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: _gold.withValues(alpha: .16),
                      width: 2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: _gold.withValues(alpha: .08),
                        blurRadius: 40,
                        spreadRadius: -12,
                      ),
                    ],
                  ),
                ),
              ),
              Image.asset(
                _duckAsset(flow),
                width: (compact ? 160 : 240) * scale,
                fit: BoxFit.contain,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _duckAsset(DuckFlow flow) {
    return switch (flow) {
      DuckFlow.extracting || DuckFlow.downloading => 'duck_loading.png',
      DuckFlow.success => 'duck_success.png',
      DuckFlow.error => 'duck_error.png',
      DuckFlow.idle || DuckFlow.ready => 'duck_idle.png',
    };
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
          const Text(
            'LOADING..',
            style: TextStyle(
              color: Colors.white,
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
                backgroundColor: Colors.white10,
                valueColor: AlwaysStoppedAnimation(_gold),
              ),
            ),
          ),
        ],
      );
    } else if (flow == DuckFlow.downloading) {
      // Look at the speed/ETA/size info if available in status or simulate size
      // We display: %progress CACHED (e.g. %8 CACHED)
      child = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '%$progress CACHED',
            style: const TextStyle(
              color: Colors.white,
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
                backgroundColor: Colors.white10,
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
      child: child,
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
                      style: const TextStyle(
                        color: Colors.white,
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
                    color: const Color(0xFF2A2A2C),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: selected,
                      isExpanded: true,
                      dropdownColor: const Color(0xFF2A2A2C),
                      style: const TextStyle(color: Colors.white, fontSize: 13),
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
          if (controller.selectedType == DownloadType.video ||
              controller.selectedType == DownloadType.audio) ...[
            const SizedBox(height: 12),
            InkWell(
              onTap: () {
                if (!controller.isMusicPremiumActive) {
                  _showPremiumSheet(context, controller);
                } else {
                  controller.toggleRemoveMusic(!controller.removeMusic);
                }
              },
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.music_off,
                      color: controller.removeMusic ? _gold : _muted,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Remove Background Music',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (!controller.isMusicPremiumActive) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _gold.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                      color: _gold.withValues(alpha: 0.3),
                                      width: 0.5,
                                    ),
                                  ),
                                  child: Text(
                                    'PRO',
                                    style: TextStyle(
                                      color: _gold,
                                      fontSize: 9,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Isolate vocals/dialogue using Demucs AI',
                            style: TextStyle(color: _muted, fontSize: 10),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value:
                          controller.removeMusic &&
                          controller.isMusicPremiumActive,
                      activeThumbColor: _gold,
                      activeTrackColor: _gold.withValues(alpha: 0.3),
                      inactiveThumbColor: _muted,
                      inactiveTrackColor: Colors.white.withValues(alpha: 0.08),
                      onChanged: (val) {
                        if (!controller.isMusicPremiumActive) {
                          _showPremiumSheet(context, controller);
                        } else {
                          controller.toggleRemoveMusic(val);
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
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
              onPressed: controller.busy ? null : controller.startDownload,
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
                '${items.length} items found',
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
                  onTap: () => setState(() => _selectedMode = _BatchDownloadMode.hybrid),
                ),
              _Chip(
                active: _selectedMode == _BatchDownloadMode.image,
                icon: Icons.image,
                label: 'Image',
                onTap: () => setState(() => _selectedMode = _BatchDownloadMode.image),
              ),
              _Chip(
                active: _selectedMode == _BatchDownloadMode.video,
                icon: Icons.play_arrow,
                label: 'Video',
                onTap: () => setState(() => _selectedMode = _BatchDownloadMode.video),
              ),
              _Chip(
                active: _selectedMode == _BatchDownloadMode.audio,
                icon: Icons.music_note,
                label: 'Audio',
                onTap: () => setState(() => _selectedMode = _BatchDownloadMode.audio),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            height: 180,
            decoration: BoxDecoration(
              color: _isLight ? const Color(0xFFF1F1F3) : const Color(0xFF1C1C1E),
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
                                style: TextStyle(
                                  color: _text,
                                  fontSize: 13,
                                ),
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
                  : () async {
                      final urls = _selectedUrls.toList();
                      DownloadType dlType;
                      if (_selectedMode == _BatchDownloadMode.image) {
                        dlType = DownloadType.image;
                      } else if (_selectedMode == _BatchDownloadMode.audio) {
                        dlType = DownloadType.audio;
                      } else {
                        dlType = DownloadType.video;
                      }
                      await widget.controller.startBatchDownload(
                        urls: urls,
                        type: dlType,
                        quality: _selectedQuality,
                        forceHybrid: _selectedMode == _BatchDownloadMode.hybrid,
                      );
                      widget.controller.clearBatch();
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
                  style: TextStyle(
                    color: _muted,
                    fontWeight: FontWeight.w900,
                  ),
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



enum _LibrarySubTab { all, favorites, playlists }

class _LibraryView extends StatefulWidget {
  const _LibraryView({
    required this.title,
    required this.items,
    required this.empty,
    required this.controller,
  });

  final String title;
  final List<DownloadItem> items;
  final String empty;
  final DuckDownloadsController controller;

  @override
  State<_LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<_LibraryView> {
  _LibrarySubTab _subTab = _LibrarySubTab.all;

  Widget _buildSubTabButton(_LibrarySubTab tab, String label) {
    final active = _subTab == tab;
    return InkWell(
      onTap: () => setState(() => _subTab = tab),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: active ? _gold : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: active ? _gold : _border),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? const Color(0xFF101112) : _textMuted,
            fontWeight: FontWeight.bold,
            fontSize: 12,
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
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
      child: Column(
        children: [
          Row(
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
                child: Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _text,
                    fontSize: 24,
                    letterSpacing: 6,
                    fontWeight: FontWeight.w300,
                  ),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(
                      Icons.lock_outline,
                      color: _gold,
                      size: 24,
                    ),
                    onPressed: () {
                      _showVaultPinDialog(
                        context,
                        widget.controller,
                        onSuccess: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) =>
                                  _SecureVaultView(controller: widget.controller),
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
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildSubTabButton(_LibrarySubTab.all, 'ALL'),
              const SizedBox(width: 12),
              _buildSubTabButton(_LibrarySubTab.favorites, 'FAVORITES'),
              const SizedBox(width: 12),
              _buildSubTabButton(_LibrarySubTab.playlists, 'PLAYLISTS'),
            ],
          ),
          const SizedBox(height: 22),
          Expanded(
            child: _subTab == _LibrarySubTab.playlists
                ? _buildPlaylistsTab()
                : filteredItems.isEmpty
                ? Center(
                    child: Text(
                      _subTab == _LibrarySubTab.favorites
                          ? 'No favorites added yet.'
                          : widget.empty,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _textMuted,
                        fontSize: 18,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 28),
                    itemBuilder: (context, index) => _DownloadRow(
                      item: filteredItems[index],
                      controller: widget.controller,
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
                  padding: const EdgeInsets.only(bottom: 28),
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
                        border: Border.all(
                          color: Colors.white.withValues(alpha: .03),
                        ),
                      ),
                      child: ListTile(
                        leading: Icon(
                          Icons.playlist_play,
                          color: _gold,
                          size: 28,
                        ),
                        title: Text(
                          playlist.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: Text(
                          '${playlistItems.length} items',
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
                            MaterialPageRoute(
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
  const _DownloadRow({required this.item, required this.controller});

  final DownloadItem item;
  final DuckDownloadsController controller;

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
            children: [
              _dot(),
              const SizedBox(width: 4),
              _dot(),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dot(),
              const SizedBox(width: 4),
              _dot(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dot() {
    return Container(
      width: 5,
      height: 5,
      decoration: BoxDecoration(
        color: _gold,
        shape: BoxShape.circle,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sizeStr = _getFileSize(item);
    final subtitle = item.artist != null && item.artist!.trim().isNotEmpty
        ? '${item.artist!} • $sizeStr'
        : sizeStr;
    return SizedBox(
      height: 86,
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: () => controller.openPlayer(item),
              child: Row(
                children: [
                  _Thumb(
                    url: item.thumbnail,
                    width: 58,
                    height: 66,
                    icon: item.isImage
                        ? Icons.image
                        : item.isAudio
                        ? Icons.music_note
                        : Icons.play_arrow,
                    radius: 8,
                  ),
                  const SizedBox(width: 22),
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            onSelected: (value) {
              switch (value) {
                case 'view':
                  controller.openPlayer(item);
                case 'share':
                  controller.shareDownload(item);
                case 'rename':
                  _showRenameDialog(context, item, controller);
                case 'save':
                  if (item.isImage) {
                    controller.saveImageExternally(item);
                  } else if (item.isVideo) {
                    controller.saveVideoExternally(item);
                  } else {
                    controller.saveAudioExternally(item);
                  }
                case 'delete':
                  controller.deleteDownload(item);
                case 'favorite':
                  controller.toggleFavorite(item);
                case 'playlist':
                  _showPlaylistSelectionSheet(context, item, controller);
                case 'vault':
                  controller.moveItemToVault(item);
                case 'edit_tag':
                  _showMetadataEditDialog(context, item, controller);
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
                    Text(
                      'Share',
                      style: TextStyle(color: _text, fontSize: 14),
                    ),
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
              const PopupMenuDivider(height: 1),
              PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    const Icon(Icons.delete_outline, color: _danger, size: 20),
                    const SizedBox(width: 12),
                    Text(
                      'Delete',
                      style: TextStyle(color: _danger, fontSize: 14, fontWeight: FontWeight.bold),
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



class _MiniPlayer extends StatelessWidget {
  const _MiniPlayer({required this.controller});
  final DuckDownloadsController controller;

  @override
  Widget build(BuildContext context) {
    final item = controller.playingItem;
    if (item == null) return const SizedBox.shrink();

    final audio = controller.audioPlayer;
    final playing = audio.playing;
    final isCompleted = audio.processingState == ProcessingState.completed;

    return GestureDetector(
      onTap: () => controller.openPlayer(item),
      child: Container(
        height: 64,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E20),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: _Thumb(
                url: item.thumbnail,
                width: 48,
                height: 48,
                icon: Icons.music_note,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.artist ?? 'Audio file',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: _warmGold, fontSize: 12),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(
                isCompleted
                    ? Icons.replay
                    : playing
                    ? Icons.pause
                    : Icons.play_arrow,
                color: Colors.white,
                size: 24,
              ),
              onPressed: () {
                if (isCompleted) {
                  audio.seek(Duration.zero);
                  audio.play();
                } else {
                  playing ? audio.pause() : audio.play();
                }
              },
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white70, size: 22),
              onPressed: controller.stopAudio,
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayerOverlay extends StatefulWidget {
  const _PlayerOverlay({required this.item, required this.controller});

  final DownloadItem item;
  final DuckDownloadsController controller;

  @override
  State<_PlayerOverlay> createState() => _PlayerOverlayState();
}

class _PlayerOverlayState extends State<_PlayerOverlay> {
  VideoPlayerController? _video;
  String? _error;
  BoxFit _videoFit = BoxFit.contain;
  bool _muted = false;
  double _speed = 1;
  static const _channel = MethodChannel('duck_downloader/media');
  bool _showControls = true;
  Timer? _hideTimer;
  bool _isInPiP = false;

  // Double-tap seek overlays
  bool _showLeftSeekIndicator = false;
  bool _showRightSeekIndicator = false;
  Timer? _leftSeekTimer;
  Timer? _rightSeekTimer;

  // Center play/pause overlays
  bool _showCenterPlayIndicator = false;
  bool _showCenterPauseIndicator = false;
  Timer? _centerPlayPauseTimer;

  // Aspect ratio fit toast overlay
  String? _fitLabel;
  Timer? _fitLabelTimer;

  // Trimming fields
  bool _isTrimmingMode = false;
  double _trimStart = 0.0;
  double _trimEnd = 1.0;
  bool _isSavingTrim = false;

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pipModeChanged') {
        final bool inPiP = call.arguments as bool;
        setState(() {
          _isInPiP = inPiP;
          if (inPiP) {
            _showControls = false;
          } else {
            _showControls = true;
          }
        });
      }
    });

    final filePath = widget.item.filePath;
    if (filePath == null) return;
    if (widget.item.isVideo) {
      _video = VideoPlayerController.file(File(filePath))
        ..initialize()
            .then((_) {
              if (!mounted) return;
              _video?.setPlaybackSpeed(_speed);
              _video?.addListener(_videoListener);
              setState(() {
                _trimStart = 0.0;
                _trimEnd = _video!.value.duration.inSeconds.toDouble();
              });
              _video?.play();
              _startHideTimer();
            })
            .catchError((Object _) {
              if (mounted) {
                setState(() => _error = 'This file could not be played.');
              }
            });
    } else {
      // Audio is managed persistently in controller
      if (widget.controller.playingItem?.id != widget.item.id) {
        widget.controller.playItem(widget.item).then((_) {
          if (!mounted) return;
          setState(() {
            _trimStart = 0.0;
            _trimEnd = (widget.controller.audioPlayer.duration ?? Duration.zero)
                .inSeconds
                .toDouble();
          });
        });
      } else {
        _trimStart = 0.0;
        _trimEnd = (widget.controller.audioPlayer.duration ?? Duration.zero)
            .inSeconds
            .toDouble();
      }
    }
  }

  void _videoListener() {
    final video = _video;
    if (video == null) return;
    final isPlaying = video.value.isPlaying;
    _channel.invokeMethod('setVideoPlaying', {'playing': isPlaying});
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _video?.value.isPlaying == true) {
        setState(() => _showControls = false);
      }
    });
  }

  void _resetHideTimer() {
    if (_showControls) {
      _startHideTimer();
    }
  }

  void _toggleControls() {
    if (_isInPiP) return;
    setState(() {
      _showControls = !_showControls;
      if (_showControls) {
        _startHideTimer();
      } else {
        _hideTimer?.cancel();
      }
    });
  }

  Future<void> _enterPiP() async {
    try {
      await _channel.invokeMethod('enterPiP');
    } catch (e) {
      debugPrint("Failed to enter PiP mode: $e");
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _leftSeekTimer?.cancel();
    _rightSeekTimer?.cancel();
    _centerPlayPauseTimer?.cancel();
    _fitLabelTimer?.cancel();
    _video?.removeListener(_videoListener);
    _channel.invokeMethod('setVideoPlaying', {'playing': false});
    _channel.setMethodCallHandler(null);
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Positioned.fill(
        child: Container(
          color: Colors.black.withValues(alpha: .9),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _PlayerHeader(
                    item: widget.item,
                    onClose: widget.controller.closePlayer,
                  ),
                  const SizedBox(height: 12),
                  _PlayerError(
                    message: _error!,
                    onDelete: () =>
                        widget.controller.deleteDownload(widget.item),
                    onDismiss: () => setState(() => _error = null),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (widget.item.filePath == null) {
      return Positioned.fill(
        child: Container(
          color: Colors.black.withValues(alpha: .9),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _PlayerHeader(
                    item: widget.item,
                    onClose: widget.controller.closePlayer,
                  ),
                  const SizedBox(height: 12),
                  const Expanded(
                    child: Center(
                      child: Text(
                        'File is not available locally.',
                        style: TextStyle(color: Color(0xFFD9D9D9)),
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

    if (widget.item.isVideo) {
      return _buildFullscreenVideoPlayer();
    } else {
      return _buildAudioPlayerLayout();
    }
  }

  Widget _buildFullscreenVideoPlayer() {
    final video = _video;
    if (video == null || !video.value.isInitialized) {
      return Positioned.fill(
        child: Container(
          color: Colors.black,
          child: Center(child: CircularProgressIndicator(color: _gold)),
        ),
      );
    }

    final value = video.value;
    final isCompleted =
        value.isInitialized &&
        value.duration > Duration.zero &&
        value.position >= value.duration;

    if (_isInPiP) {
      return Positioned.fill(
        child: Container(
          color: Colors.black,
          child: Center(
            child: FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: value.size.width,
                height: value.size.height,
                child: VideoPlayer(video),
              ),
            ),
          ),
        ),
      );
    }

    return Positioned.fill(
      child: Container(
        color: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: _toggleControls,
                onDoubleTapDown: (details) {
                  final screenWidth = MediaQuery.sizeOf(context).width;
                  final tapX = details.globalPosition.dx;
                  _resetHideTimer();
                  if (tapX < screenWidth / 2) {
                    _seekVideo(const Duration(seconds: -10));
                    _triggerLeftSeek();
                  } else {
                    _seekVideo(const Duration(seconds: 10));
                    _triggerRightSeek();
                  }
                },
                behavior: HitTestBehavior.opaque,
                child: Center(
                  child: FittedBox(
                    fit: _videoFit,
                    child: SizedBox(
                      width: value.size.width,
                      height: value.size.height,
                      child: VideoPlayer(video),
                    ),
                  ),
                ),
              ),
            ),
            if (_showLeftSeekIndicator)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: MediaQuery.sizeOf(context).width / 2,
                child: Center(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0.0, end: 1.0),
                    duration: const Duration(milliseconds: 600),
                    builder: (context, value, child) {
                      return Opacity(
                        opacity: (1.0 - value).clamp(0.0, 1.0),
                        child: Transform.scale(
                          scale: 0.8 + 0.4 * value,
                          child: child,
                        ),
                      );
                    },
                    child: Container(
                      width: 70,
                      height: 70,
                      decoration: const BoxDecoration(
                        color: Colors.black45,
                        shape: BoxShape.circle,
                      ),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.fast_rewind, color: Colors.white, size: 30),
                          SizedBox(height: 4),
                          Text(
                            '-10s',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (_showRightSeekIndicator)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: MediaQuery.sizeOf(context).width / 2,
                child: Center(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0.0, end: 1.0),
                    duration: const Duration(milliseconds: 600),
                    builder: (context, value, child) {
                      return Opacity(
                        opacity: (1.0 - value).clamp(0.0, 1.0),
                        child: Transform.scale(
                          scale: 0.8 + 0.4 * value,
                          child: child,
                        ),
                      );
                    },
                    child: Container(
                      width: 70,
                      height: 70,
                      decoration: const BoxDecoration(
                        color: Colors.black45,
                        shape: BoxShape.circle,
                      ),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.fast_forward, color: Colors.white, size: 30),
                          SizedBox(height: 4),
                          Text(
                            '+10s',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (_fitLabel != null)
              Positioned.fill(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      _fitLabel!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
              ),
            _buildCenterPlayPauseIndicator(),
            AnimatedOpacity(
              opacity: _showControls ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 250),
              child: IgnorePointer(
                ignoring: !_showControls,
                child: Stack(
                  children: [
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: ClipRRect(
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                          child: Container(
                            height: 90,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.25),
                            ),
                            child: SafeArea(
                              bottom: false,
                              child: Row(
                                children: [
                                  IconButton(
                                    onPressed: widget.controller.closePlayer,
                                    icon: Icon(
                                      Icons.keyboard_return,
                                      color: _warmGold,
                                      size: 30,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      widget.item.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Picture in Picture',
                                    onPressed: _enterPiP,
                                    icon: const Icon(
                                      Icons.picture_in_picture_alt,
                                      color: Colors.white,
                                      size: 28,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (!_isTrimmingMode)
                      Center(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            IconButton(
                              icon: const Icon(
                                Icons.replay_10,
                                size: 48,
                                color: Colors.white,
                              ),
                              onPressed: () {
                                _resetHideTimer();
                                _seekVideo(const Duration(seconds: -10));
                              },
                            ),
                            IconButton(
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.black38,
                                fixedSize: const Size(70, 70),
                              ),
                              icon: Icon(
                                isCompleted
                                    ? Icons.replay
                                    : value.isPlaying
                                    ? Icons.pause
                                    : Icons.play_arrow,
                                size: 44,
                                color: Colors.white,
                              ),
                              onPressed: () {
                                _resetHideTimer();
                                if (isCompleted) {
                                  video.seekTo(Duration.zero);
                                  video.play();
                                  _triggerPlayPauseOverlay(true);
                                } else {
                                  if (value.isPlaying) {
                                    video.pause();
                                    _triggerPlayPauseOverlay(false);
                                  } else {
                                    video.play();
                                    _triggerPlayPauseOverlay(true);
                                  }
                                }
                              },
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.forward_10,
                                size: 48,
                                color: Colors.white,
                              ),
                              onPressed: () {
                                _resetHideTimer();
                                _seekVideo(const Duration(seconds: 10));
                              },
                            ),
                          ],
                        ),
                      ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: ClipRRect(
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.25),
                            ),
                            child: SafeArea(
                              top: false,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (_isTrimmingMode) ...[
                                    _buildTrimmingSlider(value.duration),
                                  ] else ...[
                                    ValueListenableBuilder<VideoPlayerValue>(
                                      valueListenable: video,
                                      builder: (context, val, child) {
                                        return _MediaSlider(
                                          position: val.position,
                                          duration: val.duration,
                                          onChanged: (pos) {
                                            _resetHideTimer();
                                            video.seekTo(pos);
                                          },
                                        );
                                      },
                                    ),
                                  ],
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  if (!_isTrimmingMode) ...[
                                    Row(
                                      children: [
                                        IconButton(
                                          icon: Icon(
                                            _muted
                                                ? Icons.volume_off
                                                : Icons.volume_up,
                                            color: Colors.white,
                                          ),
                                          onPressed: () {
                                            _resetHideTimer();
                                            _toggleMute();
                                          },
                                        ),
                                        IconButton(
                                          icon: Icon(
                                            _videoFit == BoxFit.contain
                                                ? Icons.fit_screen
                                                : Icons.crop_free,
                                            color: Colors.white,
                                          ),
                                          onPressed: () {
                                            _resetHideTimer();
                                            _toggleFit();
                                          },
                                        ),
                                        const SizedBox(width: 8),
                                        PopupMenuButton<double>(
                                          tooltip: 'Speed',
                                          color: const Color(0xFF202124),
                                          onSelected: (spd) {
                                            _resetHideTimer();
                                            _setSpeed(spd);
                                          },
                                          itemBuilder: (context) => const [
                                            PopupMenuItem(
                                              value: .75,
                                              child: Text('0.75x'),
                                            ),
                                            PopupMenuItem(
                                              value: 1,
                                              child: Text('1x'),
                                            ),
                                            PopupMenuItem(
                                              value: 1.25,
                                              child: Text('1.25x'),
                                            ),
                                            PopupMenuItem(
                                              value: 1.5,
                                              child: Text('1.5x'),
                                            ),
                                            PopupMenuItem(
                                              value: 2,
                                              child: Text('2x'),
                                            ),
                                          ],
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.white.withValues(
                                                alpha: 0.08,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            child: Text(
                                              '${_speed.toStringAsFixed(_speed == _speed.roundToDouble() ? 0 : 2)}x',
                                              style: TextStyle(
                                                color: _gold,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        IconButton(
                                          tooltip: 'Trim video',
                                          icon: const Icon(
                                            Icons.content_cut,
                                            color: Colors.white,
                                          ),
                                          onPressed: () {
                                            setState(() {
                                              _isTrimmingMode = true;
                                              _trimStart = 0.0;
                                              _trimEnd = value
                                                  .duration
                                                  .inSeconds
                                                  .toDouble();
                                            });
                                          },
                                        ),
                                      ],
                                    ),
                                    IconButton(
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        color: Colors.white,
                                      ),
                                      onPressed: () {
                                        widget.controller.closePlayer();
                                        widget.controller.deleteDownload(
                                          widget.item,
                                        );
                                      },
                                    ),
                                  ] else ...[
                                    Row(
                                      children: [
                                        TextButton(
                                          onPressed: () => setState(
                                            () => _isTrimmingMode = false,
                                          ),
                                          child: const Text(
                                            'Cancel',
                                            style: TextStyle(
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        _isSavingTrim
                                            ? SizedBox(
                                                width: 20,
                                                height: 20,
                                                child:
                                                    CircularProgressIndicator(
                                                      color: _gold,
                                                      strokeWidth: 2,
                                                    ),
                                              )
                                            : TextButton(
                                                onPressed: _performTrim,
                                                child: Text(
                                                  'Save Trim',
                                                  style: TextStyle(
                                                    color: _gold,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  ),
);
  }

  Widget _buildAudioPlayerLayout() {
    final audio = widget.controller.audioPlayer;
    final duration = audio.duration ?? Duration.zero;
    final position = audio.position;
    final playing = audio.playing;
    final isCompleted = audio.processingState == ProcessingState.completed;

    if (_isInPiP) {
      return const SizedBox.shrink();
    }

    final screenHeight = MediaQuery.sizeOf(context).height;
    final scale = (screenHeight / 820).clamp(0.45, 1.0);
    final diskSize = 220.0 * scale;
    final spacingSize = 32.0 * scale;

    return Positioned.fill(
      child: Container(
        color: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: _toggleControls,
                behavior: HitTestBehavior.opaque,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: diskSize,
                        height: diskSize,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: _gold.withValues(alpha: 0.15),
                              blurRadius: 40 * scale,
                              spreadRadius: 8 * scale,
                            ),
                          ],
                        ),
                        child: ClipOval(
                          child: _Thumb(
                            url: widget.item.thumbnail,
                            width: diskSize,
                            height: diskSize,
                            icon: Icons.music_note,
                          ),
                        ),
                      ),
                      SizedBox(height: spacingSize),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 40 * scale),
                        child: Text(
                          widget.item.title,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 20 * scale,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      if (widget.item.artist != null &&
                          widget.item.artist!.isNotEmpty) ...[
                        SizedBox(height: 8 * scale),
                        Text(
                          widget.item.artist!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _warmGold,
                            fontSize: 15 * scale,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            AnimatedOpacity(
              opacity: _showControls ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 250),
              child: IgnorePointer(
                ignoring: !_showControls,
                child: Stack(
                  children: [
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        height: 90,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Colors.black54, Colors.transparent],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        ),
                        child: SafeArea(
                          bottom: false,
                          child: Row(
                            children: [
                              IconButton(
                                onPressed: widget.controller.closePlayer,
                                icon: Icon(
                                  Icons.keyboard_return,
                                  color: _warmGold,
                                  size: 30,
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: Text(
                                  'NOW PLAYING',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 2,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (!_isTrimmingMode)
                      Center(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            IconButton(
                              icon: const Icon(
                                Icons.replay_10,
                                size: 48,
                                color: Colors.white,
                              ),
                              onPressed: () {
                                _resetHideTimer();
                                _seekAudio(const Duration(seconds: -10));
                              },
                            ),
                            IconButton(
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.black38,
                                fixedSize: const Size(70, 70),
                              ),
                              icon: Icon(
                                isCompleted
                                    ? Icons.replay
                                    : playing
                                    ? Icons.pause
                                    : Icons.play_arrow,
                                size: 44,
                                color: Colors.white,
                              ),
                              onPressed: () {
                                _resetHideTimer();
                                if (isCompleted) {
                                  audio.seek(Duration.zero);
                                  audio.play();
                                } else {
                                  playing ? audio.pause() : audio.play();
                                }
                              },
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.forward_10,
                                size: 48,
                                color: Colors.white,
                              ),
                              onPressed: () {
                                _resetHideTimer();
                                _seekAudio(const Duration(seconds: 10));
                              },
                            ),
                          ],
                        ),
                      ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.8),
                            ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        ),
                        child: SafeArea(
                          top: false,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_isTrimmingMode) ...[
                                _buildTrimmingSlider(duration),
                              ] else ...[
                                _MediaSlider(
                                  position: position,
                                  duration: duration,
                                  onChanged: (pos) {
                                    _resetHideTimer();
                                    audio.seek(pos);
                                  },
                                ),
                              ],
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  if (!_isTrimmingMode) ...[
                                    Row(
                                      children: [
                                        PopupMenuButton<double>(
                                          tooltip: 'Speed',
                                          color: const Color(0xFF202124),
                                          onSelected: (spd) {
                                            _resetHideTimer();
                                            _setSpeed(spd);
                                          },
                                          itemBuilder: (context) => const [
                                            PopupMenuItem(
                                              value: .75,
                                              child: Text('0.75x'),
                                            ),
                                            PopupMenuItem(
                                              value: 1,
                                              child: Text('1x'),
                                            ),
                                            PopupMenuItem(
                                              value: 1.25,
                                              child: Text('1.25x'),
                                            ),
                                            PopupMenuItem(
                                              value: 1.5,
                                              child: Text('1.5x'),
                                            ),
                                            PopupMenuItem(
                                              value: 2,
                                              child: Text('2x'),
                                            ),
                                          ],
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.white.withValues(
                                                alpha: 0.08,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                            ),
                                            child: Text(
                                              '${_speed.toStringAsFixed(_speed == _speed.roundToDouble() ? 0 : 2)}x',
                                              style: TextStyle(
                                                color: _gold,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        IconButton(
                                          tooltip: 'Trim audio',
                                          icon: const Icon(
                                            Icons.content_cut,
                                            color: Colors.white,
                                          ),
                                          onPressed: () {
                                            setState(() {
                                              _isTrimmingMode = true;
                                              _trimStart = 0.0;
                                              _trimEnd = duration.inSeconds
                                                  .toDouble();
                                            });
                                          },
                                        ),
                                      ],
                                    ),
                                    IconButton(
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        color: Colors.white,
                                      ),
                                      onPressed: () {
                                        widget.controller.closePlayer();
                                        widget.controller.deleteDownload(
                                          widget.item,
                                        );
                                      },
                                    ),
                                  ] else ...[
                                    Row(
                                      children: [
                                        TextButton(
                                          onPressed: () => setState(
                                            () => _isTrimmingMode = false,
                                          ),
                                          child: const Text(
                                            'Cancel',
                                            style: TextStyle(
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        _isSavingTrim
                                            ? SizedBox(
                                                width: 20,
                                                height: 20,
                                                child:
                                                    CircularProgressIndicator(
                                                      color: _gold,
                                                      strokeWidth: 2,
                                                    ),
                                              )
                                            : TextButton(
                                                onPressed: _performTrim,
                                                child: Text(
                                                  'Save Trim',
                                                  style: TextStyle(
                                                    color: _gold,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrimmingSlider(Duration duration) {
    final maxSec = duration.inSeconds.toDouble();
    final validMax = maxSec > 0 ? maxSec : 1.0;
    final currentStart = _trimStart.clamp(0.0, validMax);
    final currentEnd = _trimEnd.clamp(currentStart, validMax);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RangeSlider(
          values: RangeValues(currentStart, currentEnd),
          min: 0,
          max: validMax,
          activeColor: _gold,
          inactiveColor: Colors.white24,
          onChanged: (RangeValues val) {
            setState(() {
              _trimStart = val.start;
              _trimEnd = val.end;
            });
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatDuration(Duration(seconds: currentStart.toInt())),
                style: TextStyle(
                  color: _gold,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                _formatDuration(Duration(seconds: currentEnd.toInt())),
                style: TextStyle(
                  color: _gold,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _performTrim() async {
    setState(() => _isSavingTrim = true);
    try {
      await widget.controller.trimDownload(
        widget.item,
        startTime: _trimStart,
        endTime: _trimEnd,
      );
      widget.controller.closePlayer();
    } catch (e) {
      setState(() {
        _error = 'Trimming failed: $e';
        _isSavingTrim = false;
      });
    }
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = duration.inHours;
    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  Future<void> _seekVideo(Duration delta) async {
    final video = _video;
    if (video == null) return;
    final next = video.value.position + delta;
    await video.seekTo(_clampDuration(next, video.value.duration));
  }

  Future<void> _seekAudio(Duration delta) async {
    final audio = widget.controller.audioPlayer;
    final next = audio.position + delta;
    await audio.seek(_clampDuration(next, audio.duration ?? Duration.zero));
  }

  Duration _clampDuration(Duration value, Duration max) {
    if (value < Duration.zero) return Duration.zero;
    if (max > Duration.zero && value > max) return max;
    return value;
  }

  Future<void> _toggleMute() async {
    final video = _video;
    if (video == null) return;
    _muted = !_muted;
    await video.setVolume(_muted ? 0 : 1);
    setState(() {});
  }

  void _toggleFit() {
    _fitLabelTimer?.cancel();
    setState(() {
      String label;
      if (_videoFit == BoxFit.contain) {
        _videoFit = BoxFit.cover;
        label = "Zoom";
      } else if (_videoFit == BoxFit.cover) {
        _videoFit = BoxFit.fill;
        label = "Stretch";
      } else {
        _videoFit = BoxFit.contain;
        label = "Fit";
      }
      _fitLabel = label;
    });
    _fitLabelTimer = Timer(const Duration(milliseconds: 1000), () {
      if (mounted) {
        setState(() => _fitLabel = null);
      }
    });
  }

  void _triggerLeftSeek() {
    _leftSeekTimer?.cancel();
    setState(() {
      _showLeftSeekIndicator = true;
      _showRightSeekIndicator = false;
    });
    _leftSeekTimer = Timer(const Duration(milliseconds: 650), () {
      if (mounted) {
        setState(() => _showLeftSeekIndicator = false);
      }
    });
  }

  void _triggerRightSeek() {
    _rightSeekTimer?.cancel();
    setState(() {
      _showLeftSeekIndicator = false;
      _showRightSeekIndicator = true;
    });
    _rightSeekTimer = Timer(const Duration(milliseconds: 650), () {
      if (mounted) {
        setState(() => _showRightSeekIndicator = false);
      }
    });
  }

  void _triggerPlayPauseOverlay(bool isPlay) {
    _centerPlayPauseTimer?.cancel();
    setState(() {
      if (isPlay) {
        _showCenterPlayIndicator = true;
        _showCenterPauseIndicator = false;
      } else {
        _showCenterPlayIndicator = false;
        _showCenterPauseIndicator = true;
      }
    });
    _centerPlayPauseTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) {
        setState(() {
          _showCenterPlayIndicator = false;
          _showCenterPauseIndicator = false;
        });
      }
    });
  }

  Widget _buildCenterPlayPauseIndicator() {
    final showPlay = _showCenterPlayIndicator;
    final showPause = _showCenterPauseIndicator;
    if (!showPlay && !showPause) return const SizedBox.shrink();

    return Positioned.fill(
      child: Center(
        child: TweenAnimationBuilder<double>(
          key: ValueKey('${showPlay ? "play" : "pause"}_indicator'),
          tween: Tween(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 450),
          builder: (context, value, child) {
            return Opacity(
              opacity: (1.0 - value).clamp(0.0, 1.0),
              child: Transform.scale(
                scale: 0.8 + 0.5 * value,
                child: child,
              ),
            );
          },
          child: Container(
            width: 70,
            height: 70,
            decoration: const BoxDecoration(
              color: Colors.black45,
              shape: BoxShape.circle,
            ),
            child: Icon(
              showPlay ? Icons.play_arrow : Icons.pause,
              color: Colors.white,
              size: 40,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _setSpeed(double speed) async {
    _speed = speed;
    await _video?.setPlaybackSpeed(speed);
    widget.controller.setAudioSpeed(speed);
    setState(() {});
  }
}

class _PlayerHeader extends StatelessWidget {
  const _PlayerHeader({required this.item, required this.onClose});

  final DownloadItem item;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          onPressed: onClose,
          icon: Icon(Icons.keyboard_return, color: _warmGold, size: 34),
        ),
        Expanded(
          child: Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ],
    );
  }
}

class _MediaSlider extends StatelessWidget {
  const _MediaSlider({
    required this.position,
    required this.duration,
    required this.onChanged,
  });

  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onChanged;

  @override
  Widget build(BuildContext context) {
    final total = duration.inMilliseconds;
    final current = total <= 0
        ? 0.0
        : position.inMilliseconds.clamp(0, total).toDouble();
    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3.0,
            activeTrackColor: _gold,
            inactiveTrackColor: Colors.white24,
            thumbColor: _gold,
            thumbShape: const RoundSliderThumbShape(
              enabledThumbRadius: 6.0,
            ),
            overlayColor: _gold.withValues(alpha: 0.12),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 18.0),
          ),
          child: Slider(
            value: current,
            min: 0,
            max: total <= 0 ? 1 : total.toDouble(),
            onChanged: total <= 0
                ? null
                : (value) => onChanged(Duration(milliseconds: value.round())),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_formatDuration(position), style: _timeStyle),
              Text(_formatDuration(duration), style: _timeStyle),
            ],
          ),
        ),
      ],
    );
  }
}

final _timeStyle = TextStyle(
  color: _muted,
  fontSize: 12,
  fontWeight: FontWeight.w700,
);

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

  @override
  void initState() {
    super.initState();
    _message = widget.controller.isVaultSetup
        ? 'Enter your 4-digit passcode'
        : 'Create a 4-digit vault passcode';
  }

  void _onKeyPress(String val) {
    if (_pin.length >= 4) return;
    setState(() {
      _pin += val;
      if (_pin.length == 4) {
        _handlePinComplete();
      }
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
      if (!widget.controller.isVaultSetup) {
        if (!_confirmMode) {
          setState(() {
            _firstPin = _pin;
            _pin = '';
            _confirmMode = true;
            _message = 'Confirm your vault passcode';
          });
        } else {
          if (_pin == _firstPin) {
            widget.controller.setVaultPin(_pin);
            widget.controller.checkVaultPin(_pin);
            Navigator.pop(context);
            widget.onSuccess();
          } else {
            setState(() {
              _pin = '';
              _confirmMode = false;
              _message = 'Passcodes do not match. Try again.';
            });
          }
        }
      } else {
        final correct = widget.controller.checkVaultPin(_pin);
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
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.sizeOf(context).height * 0.78,
      decoration: BoxDecoration(
        color: _dark,
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
        gradient: RadialGradient(
          center: Alignment(0, -0.4),
          radius: 1.0,
          colors: [Color(0x1CFFC52F), _dark],
        ),
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Container(
            width: 48,
            height: 5,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          const SizedBox(height: 28),
          Icon(Icons.lock_outline, color: _gold, size: 40),
          const SizedBox(height: 16),
          const Text(
            'Secure Vault',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          Text(_message, style: TextStyle(color: _muted, fontSize: 14)),
          const SizedBox(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(4, (index) {
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
          const Spacer(),
          _buildKeypad(),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildKeypad() {
    final keys = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['C', '0', 'Ã¢Å’Â«'],
    ];
    return Column(
      children: keys.map((row) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: row.map((val) {
            final isAction = val == 'C' || val == 'Ã¢Å’Â«';
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
                      } else if (val == 'Ã¢Å’Â«') {
                        _onBackspace();
                      } else {
                        _onKeyPress(val);
                      }
                    },
                    child: Center(
                      child: Text(
                        val,
                        style: TextStyle(
                          color: isAction ? _muted : Colors.white,
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

class _SecureVaultView extends StatelessWidget {
  const _SecureVaultView({required this.controller});

  final DuckDownloadsController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _dark,
      appBar: AppBar(
        backgroundColor: _nav,
        title: Text(
          'SECURE VAULT',
          style: TextStyle(
            color: _gold,
            fontWeight: FontWeight.w900,
            fontSize: 18,
            letterSpacing: 2,
          ),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
          onPressed: () {
            controller.lockVault();
            Navigator.pop(context);
          },
        ),
      ),
      body: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final items = controller.privateDownloads;
          Widget mainContent;
          if (items.isEmpty) {
            mainContent = Center(
              child: Text(
                'No private files in vault.',
                style: TextStyle(color: _muted),
              ),
            );
          } else {
            mainContent = ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final item = items[index];
                return _VaultItemTile(item: item, controller: controller);
              },
            );
          }
          return Stack(
            children: [
              mainContent,
              if (controller.playerItem != null)
                _PlayerOverlay(
                  item: controller.playerItem!,
                  controller: controller,
                ),
            ],
          );
        },
      ),
    );
  }
}

class _VaultItemTile extends StatelessWidget {
  const _VaultItemTile({required this.item, required this.controller});

  final DownloadItem item;
  final DuckDownloadsController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: .03)),
      ),
      child: Row(
        children: [
          _Thumb(
            url: item.thumbnail,
            width: 48,
            height: 48,
            icon: item.isAudio ? Icons.music_note : Icons.play_arrow,
          ),
          const SizedBox(width: 12),
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
                    fontWeight: FontWeight.bold,
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
            onPressed: () => controller.openPlayer(item),
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, color: _muted),
            color: const Color(0xFF202124),
            onSelected: (value) async {
              if (value == 'restore') {
                await controller.moveItemFromVault(item);
              } else if (value == 'delete') {
                await controller.deleteDownload(item);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'restore',
                child: Text('Restore to Library'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'delete',
                child: Text('Delete Permanent'),
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
          icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
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

          Widget mainContent;
          if (items.isEmpty) {
            mainContent = Center(
              child: Text(
                'No completed items in this playlist.',
                style: TextStyle(color: _muted),
              ),
            );
          } else {
            mainContent = ListView.separated(
              padding: const EdgeInsets.all(16),
              itemBuilder: (context, index) {
                final item = items[index];
                return Container(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: () => controller.openPlayer(item),
                          child: Row(
                            children: [
                              _Thumb(
                                url: item.thumbnail,
                                width: 58,
                                height: 66,
                                icon: item.isAudio
                                    ? Icons.music_note
                                    : Icons.play_arrow,
                                radius: 0,
                              ),
                              const SizedBox(width: 22),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Color(0xFFE7E7E7),
                                        fontSize: 18,
                                        fontWeight: FontWeight.w300,
                                      ),
                                    ),
                                    const SizedBox(height: 7),
                                    Text(
                                      item.platform,
                                      style: const TextStyle(
                                        color: Color(0xFFC8C8C8),
                                        fontSize: 14,
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

          return Stack(
            children: [
              mainContent,
              if (controller.playerItem != null)
                _PlayerOverlay(
                  item: controller.playerItem!,
                  controller: controller,
                ),
            ],
          );
        },
      ),
    );
  }
}

String _formatDuration(Duration duration) {
  final totalSeconds = duration.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

class _ImageViewerOverlay extends StatefulWidget {
  const _ImageViewerOverlay({required this.item, required this.controller});

  final DownloadItem item;
  final DuckDownloadsController controller;

  @override
  State<_ImageViewerOverlay> createState() => _ImageViewerOverlayState();
}

class _ImageViewerOverlayState extends State<_ImageViewerOverlay> {
  final TransformationController _transformController =
      TransformationController();
  String? _loadError;
  bool _showControls = true;

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
  }

  void _resetZoom() {
    _transformController.value = Matrix4.identity();
  }

  @override
  Widget build(BuildContext context) {
    final filePath = widget.item.filePath;
    final imageProvider = filePath != null
        ? FileImage(File(filePath)) as ImageProvider
        : widget.item.thumbnail != null
        ? NetworkImage(widget.item.thumbnail!) as ImageProvider
        : null;

    if (imageProvider == null) {
      return Positioned.fill(
        child: Container(
          color: Colors.black,
          child: SafeArea(
            child: Column(
              children: [
                _ImageViewerHeader(
                  item: widget.item,
                  onClose: widget.controller.closePlayer,
                ),
                const Expanded(
                  child: Center(
                    child: Text(
                      'Image file is not available.',
                      style: TextStyle(color: Color(0xFFD9D9D9)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_loadError != null) {
      return Positioned.fill(
        child: Container(
          color: Colors.black,
          child: SafeArea(
            child: Column(
              children: [
                _ImageViewerHeader(
                  item: widget.item,
                  onClose: widget.controller.closePlayer,
                ),
                const SizedBox(height: 12),
                _PlayerError(
                  message: _loadError!,
                  onDelete: () => widget.controller.deleteDownload(widget.item),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Positioned.fill(
      child: Container(
        color: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: _toggleControls,
                onScaleEnd: (_) {
                  // Reset zoom when scale returns to near-1
                  final scale = _transformController.value.getMaxScaleOnAxis();
                  if (scale <= 1.05 && scale >= 0.95) {
                    _resetZoom();
                  }
                },
                child: InteractiveViewer(
                  transformationController: _transformController,
                  minScale: 0.5,
                  maxScale: 5.0,
                  panEnabled: true,
                  child: Center(
                    child: Image(
                      image: imageProvider,
                      fit: BoxFit.contain,
                      errorBuilder: (ctx, error, _) {
                        if (!mounted) return const SizedBox.shrink();
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) {
                            setState(() {
                              _loadError = 'Could not load this image.';
                            });
                          }
                        });
                        return const SizedBox.shrink();
                      },
                    ),
                  ),
                ),
              ),
            ),
            AnimatedOpacity(
              opacity: _showControls ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 250),
              child: IgnorePointer(
                ignoring: !_showControls,
                child: Stack(
                  children: [
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        height: 90,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Colors.black54, Colors.transparent],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        ),
                        child: SafeArea(
                          bottom: false,
                          child: Row(
                            children: [
                              IconButton(
                                onPressed: widget.controller.closePlayer,
                                icon: Icon(
                                  Icons.keyboard_return,
                                  color: _warmGold,
                                  size: 30,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  widget.item.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Reset zoom',
                                icon: const Icon(
                                  Icons.zoom_out_map,
                                  color: Colors.white,
                                  size: 28,
                                ),
                                onPressed: _resetZoom,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.8),
                            ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        ),
                        child: SafeArea(
                          top: false,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              _ImageViewerAction(
                                icon: Icons.save_alt,
                                label: 'Save',
                                onTap: () => widget.controller
                                    .saveImageExternally(widget.item),
                              ),
                              _ImageViewerAction(
                                icon: Icons.share,
                                label: 'Share',
                                onTap: () => widget.controller.shareDownload(
                                  widget.item,
                                ),
                              ),
                              _ImageViewerAction(
                                icon: widget.item.favorite
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                label: widget.item.favorite
                                    ? 'Favorited'
                                    : 'Favorite',
                                color: widget.item.favorite ? _danger : null,
                                onTap: () => widget.controller.toggleFavorite(
                                  widget.item,
                                ),
                              ),
                              _ImageViewerAction(
                                icon: Icons.delete_outline,
                                label: 'Delete',
                                onTap: () {
                                  widget.controller.closePlayer();
                                  widget.controller.deleteDownload(widget.item);
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImageViewerHeader extends StatelessWidget {
  const _ImageViewerHeader({required this.item, required this.onClose});

  final DownloadItem item;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          IconButton(
            onPressed: onClose,
            icon: Icon(Icons.keyboard_return, color: _warmGold, size: 34),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageViewerAction extends StatelessWidget {
  const _ImageViewerAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? Colors.white;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: effectiveColor, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: effectiveColor,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayerError extends StatelessWidget {
  const _PlayerError({
    required this.message,
    required this.onDelete,
    this.onDismiss,
  });

  final String message;
  final VoidCallback onDelete;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .04),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _gold.withValues(alpha: .18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, height: 1.5),
          ),
          const SizedBox(height: 18),
          if (onDismiss != null) ...[
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white24),
                    ),
                    onPressed: onDismiss,
                    child: const Text('Dismiss'),
                  ),
                ),
                const SizedBox(width: 12),
              ],
            ),
          ],
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _gold,
              foregroundColor: const Color(0xFF151515),
            ),
            onPressed: onDelete,
            child: const Text('Delete'),
          ),
        ],
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
    return Center(
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxWidth: 540),
        margin: const EdgeInsets.only(top: 12),
        padding: padding,
        decoration: BoxDecoration(
          color: _panel,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: _border),
          boxShadow: _isLight
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.03),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  )
                ]
              : null,
        ),
        child: child,
      ),
    );
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
          color: active ? _gold : const Color(0xFF2A2A2C),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 17,
              color: active ? const Color(0xFF151515) : Colors.white,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: active ? const Color(0xFF151515) : Colors.white,
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
    this.icon = Icons.image,
    this.radius = 8,
  });

  final String? url;
  final double width;
  final double height;
  final IconData icon;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: width,
      height: height,
      color: const Color(0xFF292A2D),
      child: Icon(icon, color: _gold),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: url == null
          ? fallback
          : Image.network(
              url!,
              width: width,
              height: height,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback,
            ),
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
                        'Link Detected!',
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
                                side: BorderSide(
                                  color: _border,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                              onPressed: onDismiss,
                              child: const Text(
                                'Dismiss',
                                style: TextStyle(fontWeight: FontWeight.bold),
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
                              child: const Text(
                                'Extract',
                                style: TextStyle(fontWeight: FontWeight.w900),
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
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
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

class _AutoSaveToggleSwitch extends StatelessWidget {
  const _AutoSaveToggleSwitch({required this.controller});
  final DuckDownloadsController controller;

  @override
  Widget build(BuildContext context) {
    final active = controller.autoSaveVideos;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        GestureDetector(
          onTap: () => controller.toggleAutoSaveVideos(!active),
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: const Color(0xFF2C2D30),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: active ? _gold : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'ON',
                    style: TextStyle(
                      color: active ? const Color(0xFF101112) : Colors.white60,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: !active ? _gold : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'OFF',
                    style: TextStyle(
                      color: !active ? const Color(0xFF101112) : Colors.white60,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Auto save',
          style: TextStyle(
            color: Colors.white70,
            fontSize: 11,
          ),
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
      child: CustomPaint(
        painter: _DottedCirclePainter(color: color),
      ),
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

class _LibraryButton extends StatelessWidget {
  const _LibraryButton({
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DottedCircleIcon(color: _gold, size: 36),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                color: _gold,
                fontSize: 11,
                letterSpacing: 2,
                fontWeight: FontWeight.w300,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

