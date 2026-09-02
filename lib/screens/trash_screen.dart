import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/download_models.dart';
import '../state/downloads_controller.dart';
import '../theme/duck_theme.dart';
import '../widgets/ambient_background.dart';
import '../widgets/duck_motion.dart';

/// The week a deleted file gets before it is really gone.
///
/// Deleting used to call `File.delete` and that was that — one mis-tap on a
/// download that took ten minutes to fetch and it was gone. This is the other
/// half of that change: somewhere to notice the mistake.
class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key, required this.controller});

  final DuckDownloadsController controller;

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
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
            listenable: widget.controller,
            builder: (context, _) {
              final items = widget.controller.trashedItems;
              return CustomScrollView(
                slivers: [
                  SliverAppBar(
                    pinned: true,
                    backgroundColor: colors.background.withValues(alpha: 0.92),
                    foregroundColor: colors.text,
                    elevation: 0,
                    title: Text(
                      l10n.translate('trashTitle'),
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    actions: [
                      if (items.isNotEmpty)
                        TextButton(
                          onPressed: () => _confirmEmpty(context, l10n),
                          style: TextButton.styleFrom(
                            foregroundColor: DuckColors.danger,
                          ),
                          child: Text(l10n.translate('trashEmptyAll')),
                        ),
                    ],
                  ),
                  if (items.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _Empty(colors: colors, l10n: l10n),
                    )
                  else
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        18,
                        6,
                        18,
                        28 + MediaQuery.paddingOf(context).bottom,
                      ),
                      sliver: SliverList.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, index) => EntranceFade(
                          index: index.clamp(0, 6),
                          child: _TrashRow(
                            colors: colors,
                            l10n: l10n,
                            item: items[index],
                            daysLeft: widget.controller.daysLeftInTrash(
                              items[index],
                            ),
                            onRestore: () =>
                                widget.controller.restoreFromTrash(items[index]),
                            onDeleteNow: () =>
                                widget.controller.deleteForever(items[index]),
                          ),
                        ),
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

  Future<void> _confirmEmpty(BuildContext context, AppLocalizations l10n) async {
    final colors = DuckColors.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: colors.panel,
        title: Text(
          l10n.translate('trashEmptyAll'),
          style: TextStyle(color: colors.text, fontWeight: FontWeight.w800),
        ),
        content: Text(
          l10n.translate('trashEmptyBody'),
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
            child: Text(l10n.translate('trashDeleteNow')),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.controller.emptyTrash();
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.colors, required this.l10n});

  final DuckColors colors;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.delete_outline, size: 48, color: colors.textMuted),
            const SizedBox(height: 14),
            Text(
              l10n.translate('trashEmpty'),
              style: TextStyle(
                color: colors.text,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.translate('trashEmptyBody'),
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textMuted, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrashRow extends StatelessWidget {
  const _TrashRow({
    required this.colors,
    required this.l10n,
    required this.item,
    required this.daysLeft,
    required this.onRestore,
    required this.onDeleteNow,
  });

  final DuckColors colors;
  final AppLocalizations l10n;
  final DownloadItem item;
  final int daysLeft;
  final VoidCallback onRestore;
  final VoidCallback onDeleteNow;

  @override
  Widget build(BuildContext context) {
    // Counted down out loud. A file that vanishes on a schedule nobody was
    // told about is indistinguishable from one the app lost.
    final remaining = daysLeft <= 1
        ? l10n.translate('trashOneDayLeft')
        : l10n.translate('trashDaysLeft').replaceAll('{days}', '$daysLeft');

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
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
                  remaining,
                  style: TextStyle(
                    color: daysLeft <= 1 ? DuckColors.danger : colors.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: l10n.translate('trashRestore'),
            icon: Icon(Icons.restore, color: colors.gold, size: 20),
            onPressed: onRestore,
          ),
          IconButton(
            tooltip: l10n.translate('trashDeleteNow'),
            icon: const Icon(
              Icons.delete_forever_outlined,
              color: DuckColors.danger,
              size: 20,
            ),
            onPressed: onDeleteNow,
          ),
        ],
      ),
    );
  }
}
