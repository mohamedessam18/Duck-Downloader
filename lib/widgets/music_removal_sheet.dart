import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/download_models.dart';
import '../state/downloads_controller.dart';
import '../widgets/duck_motion.dart';

/// The gate between wanting the music gone and it actually happening.
///
/// Free users pay for a run with rewarded ads, Studio subscribers do not. Both
/// paths land here so the offer is made in the one place where the user has
/// already said what they want — asking before they tap would be selling to
/// someone who has not decided yet.
///
/// The feature is never shown behind a lock or a crown. A padlock next to the
/// name stops people trying it, and nobody subscribes to something they have
/// not used.
Future<void> showMusicRemovalSheet(
  BuildContext context,
  DuckDownloadsController controller, {
  required DownloadItem item,
  required VoidCallback onSubscribe,
}) {
  // Warm an ad now: the sheet is open for a few seconds while the user reads,
  // and that is exactly long enough to load one.
  controller.prepareMusicRemoval();

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _MusicRemovalSheet(
      controller: controller,
      item: item,
      onSubscribe: onSubscribe,
    ),
  );
}

class _MusicRemovalSheet extends StatelessWidget {
  const _MusicRemovalSheet({
    required this.controller,
    required this.item,
    required this.onSubscribe,
  });

  final DuckDownloadsController controller;
  final DownloadItem item;
  final VoidCallback onSubscribe;

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final gold = isLight ? const Color(0xFFC69214) : const Color(0xFFFFC52F);
    final panel = isLight ? Colors.white : const Color(0xFF1D1D1F);
    final text = isLight ? const Color(0xFF151517) : Colors.white;
    final muted = isLight ? const Color(0xFF6F707A) : const Color(0xFFB8B8B8);
    final border = isLight
        ? Colors.black.withValues(alpha: .08)
        : Colors.white.withValues(alpha: .08);

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context);
        final hasStudio = controller.hasMusicRemovalSubscription;
        final busy = controller.musicRemovalPending;

        return Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: panel,
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: border),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: gold.withValues(alpha: .16),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(Icons.graphic_eq, color: gold),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10n.translate('musicRemovalTitle'),
                                style: TextStyle(
                                  color: text,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              Text(
                                l10n.translate('musicRemovalSubtitle'),
                                style: TextStyle(color: muted, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isLight
                            ? Colors.black.withValues(alpha: .04)
                            : Colors.white.withValues(alpha: .05),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),

                    if (busy)
                      _AdProgress(
                        watched: controller.musicRemovalAdsWatched,
                        total: controller.musicRemovalAdCount,
                        gold: gold,
                        muted: muted,
                      )
                    else ...[
                      if (!hasStudio) ...[
                        _Action(
                          label: l10n
                              .translate('musicRemovalWatchAds')
                              .replaceAll(
                                '{count}',
                                '${controller.musicRemovalAdCount}',
                              ),
                          icon: Icons.play_circle_outline,
                          filled: true,
                          gold: gold,
                          onPressed: () {
                            Navigator.pop(context);
                            controller.startMusicRemoval(item, l10n);
                          },
                        ),
                        const SizedBox(height: 10),
                        _Action(
                          label: l10n.translate('musicRemovalSubscribe'),
                          icon: Icons.auto_awesome,
                          filled: false,
                          gold: gold,
                          textColor: text,
                          borderColor: border,
                          onPressed: () {
                            Navigator.pop(context);
                            onSubscribe();
                          },
                        ),
                      ] else
                        _Action(
                          label: l10n.translate('musicRemovalTitle'),
                          icon: Icons.graphic_eq,
                          filled: true,
                          gold: gold,
                          onPressed: () {
                            Navigator.pop(context);
                            controller.startMusicRemoval(item, l10n);
                          },
                        ),
                    ],

                    const SizedBox(height: 12),
                    // Says what happens next, so nobody sits watching a
                    // spinner: separation runs on a server and takes minutes.
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline, size: 15, color: muted),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n
                                .translate('musicRemovalNote')
                                .replaceAll(
                                  '{minutes}',
                                  '${controller.musicRemovalMaxDuration.inMinutes}',
                                ),
                            style: TextStyle(
                              color: muted,
                              fontSize: 11,
                              height: 1.45,
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
        );
      },
    );
  }
}

/// Where the user is in the ads they agreed to watch.
class _AdProgress extends StatelessWidget {
  const _AdProgress({
    required this.watched,
    required this.total,
    required this.gold,
    required this.muted,
  });

  final int watched;
  final int total;
  final Color gold;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        Row(
          children: [
            for (var i = 0; i < total; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              Expanded(
                child: AnimatedContainer(
                  duration: DuckMotion.pressDuration,
                  height: 4,
                  decoration: BoxDecoration(
                    color: i < watched ? gold : gold.withValues(alpha: .2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        Text(
          l10n
              .translate('musicRemovalAdProgress')
              .replaceAll('{watched}', '${watched + 1}')
              .replaceAll('{total}', '$total'),
          style: TextStyle(
            color: muted,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.label,
    required this.icon,
    required this.filled,
    required this.gold,
    required this.onPressed,
    this.textColor,
    this.borderColor,
  });

  final String label;
  final IconData icon;
  final bool filled;
  final Color gold;
  final VoidCallback onPressed;
  final Color? textColor;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: filled
          ? FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: gold,
                foregroundColor: const Color(0xFF151515),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: onPressed,
              icon: Icon(icon, size: 19),
              label: Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            )
          : OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: textColor,
                side: BorderSide(color: borderColor ?? gold),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: onPressed,
              icon: Icon(icon, size: 19, color: gold),
              label: Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
    );
  }
}
