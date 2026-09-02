import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/download_models.dart';
import '../state/downloads_controller.dart';
import '../state/storage_summary.dart';
import '../theme/duck_theme.dart';
import '../widgets/ambient_background.dart';
import '../widgets/duck_motion.dart';

/// What Duck is holding, and what to delete to get it back.
///
/// A downloader's library is the reason a phone fills up, and the app could
/// not answer the only question that matters when it does. The list of biggest
/// files is the point of the screen — a total nobody can act on is a number,
/// not an answer.
class StorageScreen extends StatelessWidget {
  const StorageScreen({super.key, required this.controller});

  final DuckDownloadsController controller;

  @override
  Widget build(BuildContext context) {
    final colors = DuckColors.of(context);
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: colors.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: AmbientBackground(
              padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
              child: const SizedBox.expand(),
            ),
          ),
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final summary = controller.storageSummary;
              return CustomScrollView(
                slivers: [
                  SliverAppBar(
                    pinned: true,
                    backgroundColor: colors.background.withValues(alpha: 0.92),
                    foregroundColor: colors.text,
                    elevation: 0,
                    title: Text(
                      l10n.translate('storageTitle'),
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
                          child: _Total(
                            colors: colors,
                            l10n: l10n,
                            summary: summary,
                          ),
                        ),
                        if (summary.slices.isNotEmpty) ...[
                          const SizedBox(height: 18),
                          EntranceFade(
                            index: 1,
                            child: _Breakdown(
                              colors: colors,
                              l10n: l10n,
                              summary: summary,
                            ),
                          ),
                        ],
                        if (summary.largest.isNotEmpty) ...[
                          const SizedBox(height: 22),
                          EntranceFade(
                            index: 2,
                            child: _SectionLabel(
                              colors: colors,
                              text: l10n.translate('storageLargest'),
                            ),
                          ),
                          const SizedBox(height: 10),
                          for (var i = 0; i < summary.largest.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: EntranceFade(
                                index: (i + 3).clamp(0, 6),
                                child: _BigFileRow(
                                  colors: colors,
                                  l10n: l10n,
                                  item: summary.largest[i],
                                  onDelete: () => controller.deleteDownload(
                                    summary.largest[i],
                                  ),
                                ),
                              ),
                            ),
                        ],
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
}

class _Total extends StatelessWidget {
  const _Total({
    required this.colors,
    required this.l10n,
    required this.summary,
  });

  final DuckColors colors;
  final AppLocalizations l10n;
  final StorageSummary summary;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 18),
      decoration: BoxDecoration(
        color: colors.panel.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(DuckColors.radiusLg),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        children: [
          Text(
            formatBytes(summary.totalBytes),
            style: TextStyle(
              color: colors.gold,
              fontSize: 40,
              fontWeight: FontWeight.w900,
              height: 1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.translate('storageTotal'),
            style: TextStyle(color: colors.textMuted, fontSize: 13),
          ),
          if (summary.trashCount > 0) ...[
            const SizedBox(height: 14),
            Text(
              l10n
                  .translate('storageInTrash')
                  .replaceAll('{size}', formatBytes(summary.trashBytes))
                  .replaceAll('{count}', '${summary.trashCount}'),
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textMuted, fontSize: 12.5),
            ),
          ],
        ],
      ),
    );
  }
}

class _Breakdown extends StatelessWidget {
  const _Breakdown({
    required this.colors,
    required this.l10n,
    required this.summary,
  });

  final DuckColors colors;
  final AppLocalizations l10n;
  final StorageSummary summary;

  @override
  Widget build(BuildContext context) {
    final total = summary.totalBytes;
    return Column(
      children: [
        for (final slice in summary.slices)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${l10n.translate(slice.labelKey)} · ${slice.count}',
                        style: TextStyle(color: colors.text, fontSize: 13.5),
                      ),
                    ),
                    Text(
                      formatBytes(slice.bytes),
                      style: TextStyle(
                        color: colors.textMuted,
                        fontSize: 13,
                        // Digits line up between rows, so the bars and the
                        // numbers can be compared at a glance.
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: total == 0 ? 0 : slice.bytes / total,
                    minHeight: 6,
                    color: colors.gold,
                    backgroundColor: colors.border,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.colors, required this.text});

  final DuckColors colors;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        color: colors.textMuted,
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.3,
      ),
    );
  }
}

class _BigFileRow extends StatelessWidget {
  const _BigFileRow({
    required this.colors,
    required this.l10n,
    required this.item,
    required this.onDelete,
  });

  final DuckColors colors;
  final AppLocalizations l10n;
  final DownloadItem item;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        color: colors.panel.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(DuckColors.radiusLg),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          Icon(
            item.isVideo
                ? Icons.videocam_outlined
                : item.isAudio
                ? Icons.music_note_outlined
                : Icons.image_outlined,
            color: colors.textMuted,
            size: 20,
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
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  formatBytes(item.fileSizeBytes ?? 0),
                  style: TextStyle(color: colors.gold, fontSize: 12.5),
                ),
              ],
            ),
          ),
          IconButton(
            // Deleting from here goes to the trash like anywhere else. This
            // screen is for freeing room, not for a second, harsher delete
            // nobody was told about.
            tooltip: l10n.translate('trashDeleteNow'),
            icon: const Icon(
              Icons.delete_outline,
              color: DuckColors.danger,
              size: 20,
            ),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}
