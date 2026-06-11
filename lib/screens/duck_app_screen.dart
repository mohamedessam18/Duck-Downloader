import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';

import '../models/download_models.dart';
import '../state/downloads_controller.dart';

const _gold = Color(0xFFFFC52F);
const _warmGold = Color(0xFFF6BD6A);
const _dark = Color(0xFF101112);
const _nav = Color(0xFF171819);
const _panel = Color(0xFF1D1D1F);
const _muted = Color(0xFFB8B8B8);
const _danger = Color(0xFFFF7A65);

class DuckAppScreen extends StatelessWidget {
  const DuckAppScreen({super.key, required this.controller});

  final DuckDownloadsController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: _dark,
          body: Stack(
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: const BoxDecoration(
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
                      bottom: 96,
                    ),
                    child: _bodyForTab(context),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: _BottomNav(controller: controller),
              ),
              if (controller.playerItem != null)
                _PlayerOverlay(
                  item: controller.playerItem!,
                  onClose: controller.closePlayer,
                  onDelete: () =>
                      controller.deleteDownload(controller.playerItem!),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _bodyForTab(BuildContext context) {
    return switch (controller.tab) {
      DuckTab.home => _HomeView(controller: controller),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(28, showQueue ? 14 : 22, 28, 16),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: _ProBadge(controller: controller),
                ),
                SizedBox(height: (showQueue ? 8 : 12) * scale),
                _Brand(compact: showQueue, scale: scale),
                SizedBox(height: (showQueue ? 16 : 26) * scale),
                _Hint(compact: showQueue, scale: scale),
                SizedBox(height: (showQueue ? 8 : 12) * scale),
                _DuckButton(
                  flow: controller.flow,
                  compact: showQueue,
                  scale: scale,
                  onTap: controller.pasteAndExtract,
                ),
                _StatusBar(
                  flow: controller.flow,
                  status: controller.status,
                  progress: active?.progress ?? 0,
                ),
                if (controller.metadata != null)
                  _OptionsCard(controller: controller)
                else if (showQueue)
                  _DownloadQueueCard(
                    controller: controller,
                    items: activeDownloads,
                  )
                else
                  _VideosCard(
                    count: controller.videos.length,
                    onTap: () => controller.setTab(DuckTab.videos),
                  ),
              ],
            ),
          ),
        );
      },
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
          'Duck',
          style: TextStyle(
            color: _gold,
            fontSize: (compact ? 48 : 58) * scale,
            fontWeight: FontWeight.w900,
            height: .9,
          ),
        ),
        SizedBox(height: (compact ? 5 : 8) * scale),
        Text(
          'DOWNLOADER',
          style: TextStyle(
            color: const Color(0xFF9A9A9A),
            fontSize: (compact ? 14 : 17) * scale,
            letterSpacing: compact ? 7 : 8,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.compact, required this.scale});

  final bool compact;
  final double scale;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 540),
      padding: EdgeInsets.symmetric(
        horizontal: (compact ? 18 : 20) * scale,
        vertical: (compact ? 12 : 15) * scale,
      ),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: Colors.white.withValues(alpha: .06)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .2),
            blurRadius: 50,
            offset: const Offset(0, 20),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(Icons.link, color: _gold, size: (compact ? 27 : 32) * scale),
          SizedBox(width: 16 * scale),
          Expanded(
            child: Text(
              'Copy a link from any social media and tap the duck to download!',
              style: TextStyle(
                color: const Color(0xFFE8E8E8),
                fontSize: (compact ? 15 : 17) * scale,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProBadge extends StatelessWidget {
  const _ProBadge({required this.controller});

  final DuckDownloadsController controller;

  @override
  Widget build(BuildContext context) {
    final active = controller.isProActive;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => _showProSheet(context, controller),
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
              active ? Icons.workspace_premium : Icons.lock_open,
              color: active ? _gold : _muted,
              size: 18,
            ),
            const SizedBox(width: 7),
            Text(
              active ? 'PRO ACTIVE' : 'PRO',
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

void _showProSheet(BuildContext context, DuckDownloadsController controller) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ProLicenseSheet(controller: controller),
  );
}

class _ProLicenseSheet extends StatefulWidget {
  const _ProLicenseSheet({required this.controller});

  final DuckDownloadsController controller;

  @override
  State<_ProLicenseSheet> createState() => _ProLicenseSheetState();
}

class _ProLicenseSheetState extends State<_ProLicenseSheet> {
  late final TextEditingController _key;

  @override
  void initState() {
    super.initState();
    _key = TextEditingController(text: widget.controller.licenseKey ?? '');
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final active = widget.controller.isProActive;
        final busy = widget.controller.licenseBusy;
        return Padding(
          padding: EdgeInsets.fromLTRB(18, 0, 18, bottom + 18),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
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
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: _gold.withValues(alpha: .16),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: const Icon(
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
                              'Lifetime Pro',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            Text(
                              active
                                  ? 'Your license is active.'
                                  : 'Unlock Pro downloads on this device.',
                              style: const TextStyle(
                                color: _muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close, color: _muted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _key,
                    enabled: !busy,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      hintText: 'DUCK-PRO-XXXX-XXXX',
                      labelText: 'License key',
                      labelStyle: const TextStyle(color: _muted),
                      filled: true,
                      fillColor: const Color(0xFF242527),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.controller.licenseStatus,
                    style: TextStyle(
                      color: active ? _gold : _muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: _gold,
                            foregroundColor: const Color(0xFF151515),
                          ),
                          onPressed: busy
                              ? null
                              : () => widget.controller.activateLicense(
                                  _key.text,
                                ),
                          child: Text(busy ? 'Checking...' : 'Activate'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton(
                        onPressed: busy || widget.controller.licenseKey == null
                            ? null
                            : () => widget.controller.verifyLicense(),
                        child: const Text('Restore'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
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
    final active = flow == DuckFlow.downloading || flow == DuckFlow.extracting;
    final value = flow == DuckFlow.success
        ? 1.0
        : active
        ? progress / 100
        : 0.0;
    return SizedBox(
      height: 54,
      child: Column(
        children: [
          Text(
            status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: flow == DuckFlow.error ? _danger : _gold,
              fontSize: 15,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: flow == DuckFlow.extracting ? null : value.clamp(0.0, 1.0),
              minHeight: 7,
              backgroundColor: const Color(0xFF333333),
              valueColor: AlwaysStoppedAnimation(
                flow == DuckFlow.error ? _danger : _gold,
              ),
            ),
          ),
          if (flow == DuckFlow.downloading)
            Text(
              '$progress%',
              style: const TextStyle(color: _muted, fontSize: 10),
            ),
        ],
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
    final formats = controller.selectedType == DownloadType.video
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
                      style: const TextStyle(color: _muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _Chip(
                active: controller.selectedType == DownloadType.video,
                icon: Icons.play_arrow,
                label: 'Video',
                onTap: () => controller.changeType(DownloadType.video),
              ),
              const SizedBox(width: 8),
              _Chip(
                active: controller.selectedType == DownloadType.audio,
                icon: Icons.music_note,
                label: 'Audio',
                onTap: () => controller.changeType(DownloadType.audio),
              ),
              const SizedBox(width: 8),
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
                  style: const TextStyle(
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
            icon: item.isAudio ? Icons.music_note : Icons.play_arrow,
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
                    valueColor: const AlwaysStoppedAnimation(_gold),
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
              style: const TextStyle(
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
              style: const TextStyle(
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

class _VideosCard extends StatelessWidget {
  const _VideosCard({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: SizedBox(
        height: 98,
        child: Row(
          children: [
            Container(
              width: 52,
              height: 42,
              decoration: BoxDecoration(
                color: _gold,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.play_arrow, color: Color(0xFF151515)),
            ),
            const SizedBox(width: 22),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'VIDEOS',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    count == 0
                        ? 'View all downloaded videos'
                        : '$count downloaded video${count == 1 ? '' : 's'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _muted, fontSize: 15),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Color(0xFF9C9C9C), size: 42),
          ],
        ),
      ),
    );
  }
}

class _LibraryView extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                onPressed: () => controller.setTab(DuckTab.home),
                icon: const Icon(
                  Icons.keyboard_return,
                  color: _warmGold,
                  size: 34,
                ),
              ),
              Expanded(
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFFEDEDED),
                    fontSize: 34,
                    letterSpacing: 10,
                    fontWeight: FontWeight.w300,
                  ),
                ),
              ),
              const SizedBox(width: 48),
            ],
          ),
          const SizedBox(height: 22),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Text(
                      empty,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFC8C8C8),
                        fontSize: 18,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 28),
                    itemBuilder: (context, index) => _DownloadRow(
                      item: items[index],
                      controller: controller,
                    ),
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, color: Color(0xFFBFBFBF)),
                    itemCount: items.length,
                  ),
          ),
        ],
      ),
    );
  }
}

class _DownloadRow extends StatelessWidget {
  const _DownloadRow({required this.item, required this.controller});

  final DownloadItem item;
  final DuckDownloadsController controller;

  @override
  Widget build(BuildContext context) {
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
                    icon: item.isAudio ? Icons.music_note : Icons.play_arrow,
                    radius: 0,
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
                          style: const TextStyle(
                            color: Color(0xFFE7E7E7),
                            fontSize: 18,
                            fontWeight: FontWeight.w300,
                          ),
                        ),
                        const SizedBox(height: 7),
                        Text(
                          item.quality ??
                              (item.isAudio ? 'Saved audio' : 'Saved video'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFC8C8C8),
                            fontSize: 15,
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
            onPressed: () => controller.shareDownload(item),
            icon: const Icon(Icons.ios_share, color: _warmGold),
          ),
          IconButton(
            onPressed: () => controller.deleteDownload(item),
            icon: const Icon(Icons.close, color: _danger),
          ),
        ],
      ),
    );
  }

  String _displayName(DownloadItem item) {
    final ext = item.isAudio ? 'mp3' : 'mp4';
    return item.title.toLowerCase().endsWith('.$ext')
        ? item.title
        : '${item.title}.$ext';
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.controller});

  final DuckDownloadsController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 96,
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 16),
      decoration: BoxDecoration(
        color: _nav,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: .05)),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .35),
            blurRadius: 28,
            offset: const Offset(0, -12),
          ),
        ],
      ),
      child: Row(
        children: [
          _NavItem(
            tab: DuckTab.home,
            current: controller.tab,
            icon: Icons.home,
            label: 'HOME',
            onTap: controller.setTab,
          ),
          _NavItem(
            tab: DuckTab.videos,
            current: controller.tab,
            icon: Icons.play_arrow,
            label: 'VIDEOS',
            onTap: controller.setTab,
          ),
          _NavItem(
            tab: DuckTab.audios,
            current: controller.tab,
            icon: Icons.music_note,
            label: 'AUDIOS',
            onTap: controller.setTab,
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.tab,
    required this.current,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final DuckTab tab;
  final DuckTab current;
  final IconData icon;
  final String label;
  final ValueChanged<DuckTab> onTap;

  @override
  Widget build(BuildContext context) {
    final active = tab == current;
    final color = active ? _gold : const Color(0xFF888888);
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => onTap(tab),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 30),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 7),
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: active ? 44 : 0,
              height: 4,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayerOverlay extends StatefulWidget {
  const _PlayerOverlay({
    required this.item,
    required this.onClose,
    required this.onDelete,
  });

  final DownloadItem item;
  final VoidCallback onClose;
  final VoidCallback onDelete;

  @override
  State<_PlayerOverlay> createState() => _PlayerOverlayState();
}

class _PlayerOverlayState extends State<_PlayerOverlay> {
  VideoPlayerController? _video;
  AudioPlayer? _audio;
  String? _error;

  @override
  void initState() {
    super.initState();
    final filePath = widget.item.filePath;
    if (filePath == null) return;
    if (widget.item.isVideo) {
      _video = VideoPlayerController.file(File(filePath))
        ..initialize()
            .then((_) {
              if (!mounted) return;
              setState(() {});
              _video?.play();
            })
            .catchError((Object _) {
              if (mounted) {
                setState(() => _error = 'This file could not be played.');
              }
            });
    } else {
      _audio = AudioPlayer()
        ..setFilePath(filePath).then((_) => _audio?.play()).catchError((
          Object _,
        ) {
          if (mounted) {
            setState(() => _error = 'This audio file could not be played.');
          }
        });
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    _audio?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: .72),
        padding: const EdgeInsets.all(22),
        child: Center(
          child: Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxWidth: 760),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: const Color(0xFF111214),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withValues(alpha: .12)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IconButton(
                  onPressed: widget.onClose,
                  icon: const Icon(
                    Icons.keyboard_return,
                    color: _warmGold,
                    size: 34,
                  ),
                ),
                Text(
                  widget.item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 16),
                if (_error != null)
                  _PlayerError(message: _error!, onDelete: widget.onDelete)
                else if (widget.item.filePath == null)
                  const Text(
                    'File is not available locally.',
                    style: TextStyle(color: Color(0xFFD9D9D9)),
                  )
                else if (widget.item.isVideo)
                  _VideoPlayerBox(controller: _video)
                else
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 80),
                    child: Center(
                      child: Icon(Icons.music_note, color: _gold, size: 64),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VideoPlayerBox extends StatelessWidget {
  const _VideoPlayerBox({required this.controller});

  final VideoPlayerController? controller;

  @override
  Widget build(BuildContext context) {
    final video = controller;
    if (video == null || !video.value.isInitialized) {
      return const SizedBox(
        height: 220,
        child: Center(child: CircularProgressIndicator(color: _gold)),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: AspectRatio(
        aspectRatio: video.value.aspectRatio,
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            VideoPlayer(video),
            VideoProgressIndicator(video, allowScrubbing: true),
            Center(
              child: IconButton.filled(
                onPressed: () =>
                    video.value.isPlaying ? video.pause() : video.play(),
                icon: Icon(
                  video.value.isPlaying ? Icons.pause : Icons.play_arrow,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayerError extends StatelessWidget {
  const _PlayerError({required this.message, required this.onDelete});

  final String message;
  final VoidCallback onDelete;

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
            style: const TextStyle(color: Colors.white, height: 1.5),
          ),
          const SizedBox(height: 18),
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
  const _Panel({required this.child, required this.padding, this.onTap});

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxWidth: 540),
          margin: const EdgeInsets.only(top: 12),
          padding: padding,
          decoration: BoxDecoration(
            color: _panel,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: .10)),
          ),
          child: child,
        ),
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
    this.icon = Icons.play_arrow,
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
