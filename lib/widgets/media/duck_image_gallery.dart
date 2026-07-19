import 'dart:io';

import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';

import '../../models/download_models.dart';
import '../../state/downloads_controller.dart';
import 'media_colors.dart';
import 'media_thumb.dart';
import 'player_error.dart';

class DuckImageGallery extends StatefulWidget {
  const DuckImageGallery({
    super.key,
    required this.item,
    required this.allImages,
    required this.controller,
  });

  final DownloadItem item;
  final List<DownloadItem> allImages;
  final DuckDownloadsController controller;

  @override
  State<DuckImageGallery> createState() => _DuckImageGalleryState();
}

class _DuckImageGalleryState extends State<DuckImageGallery> {
  late final PageController _pageController;
  late int _currentIndex;
  String? _loadError;
  bool _showControls = true;
  final Map<String, String> _decryptedPaths = {};
  final Set<String> _tempFilesToDelete = {};

  @override
  void initState() {
    super.initState();
    final images = _resolvedImages;
    _currentIndex = images.indexWhere((img) => img.id == widget.item.id);
    if (_currentIndex < 0) _currentIndex = 0;
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (final path in _tempFilesToDelete) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    super.dispose();
  }

  List<DownloadItem> get _resolvedImages {
    final withFiles =
        widget.allImages.where((item) => item.filePath != null).toList();
    return withFiles.isEmpty ? [widget.item] : withFiles;
  }

  DownloadItem get _currentItem => _resolvedImages[_currentIndex];

  void _toggleControls() => setState(() => _showControls = !_showControls);

  Future<ImageProvider?> _getEffectiveProvider(DownloadItem item) async {
    final filePath = item.filePath;
    if (filePath == null) {
      final thumb = item.thumbnail;
      if (thumb != null && thumb.startsWith('http')) {
        return NetworkImage(thumb);
      }
      return null;
    }

    if (item.isPrivate) {
      if (_decryptedPaths.containsKey(item.id)) {
        final cachedPath = _decryptedPaths[item.id]!;
        if (File(cachedPath).existsSync()) return FileImage(File(cachedPath));
      }
      try {
        final info = await widget.controller.getEffectivePathAndFileName(item);
        final decPath = info['path']!;
        _decryptedPaths[item.id] = decPath;
        _tempFilesToDelete.add(decPath);
        if (File(decPath).existsSync()) return FileImage(File(decPath));
      } catch (e) {
        debugPrint('Failed to decrypt vault image: $e');
      }
    } else {
      if (File(filePath).existsSync()) {
        return FileImage(File(filePath));
      }
    }

    final thumb = item.thumbnail;
    if (thumb != null && thumb.startsWith('http')) {
      return NetworkImage(thumb);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final images = _resolvedImages;

    if (_loadError != null) {
      return SizedBox.expand(
        child: Container(
          color: Colors.black,
          child: SafeArea(
            child: Column(
              children: [
                _GalleryHeader(
                  title: widget.item.title,
                  index: _currentIndex,
                  total: images.length,
                  onClose: widget.controller.closePlayer,
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: PlayerError(
                    message: _loadError!,
                    onDelete: () =>
                        widget.controller.deleteDownload(_currentItem),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return SizedBox.expand(
      child: Container(
        color: Colors.black,
        child: Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              itemCount: images.length,
              onPageChanged: (index) => setState(() => _currentIndex = index),
              itemBuilder: (context, index) {
                final item = images[index];
                return FutureBuilder<ImageProvider?>(
                  future: _getEffectiveProvider(item),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return Center(
                        child: CircularProgressIndicator(color: mediaGold),
                      );
                    }
                    final provider = snapshot.data;
                    if (provider == null) {
                      return const Center(
                        child: Text(
                          'Image file is not available.',
                          style: TextStyle(color: Color(0xFFD9D9D9)),
                        ),
                      );
                    }
                    return GestureDetector(
                      onTap: _toggleControls,
                      child: PhotoView(
                        imageProvider: provider,
                        minScale: PhotoViewComputedScale.contained * 0.5,
                        maxScale: PhotoViewComputedScale.covered * 4,
                        backgroundDecoration: const BoxDecoration(
                          color: Colors.black,
                        ),
                        errorBuilder: (_, _, _) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted && _loadError == null) {
                              setState(() => _loadError = 'Could not load image.');
                            }
                          });
                          return const SizedBox.shrink();
                        },
                      ),
                    );
                  },
                );
              },
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
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Colors.black54, Colors.transparent],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        ),
                        child: SafeArea(
                          bottom: false,
                          child: _GalleryHeader(
                            title: _currentItem.title,
                            index: _currentIndex,
                            total: images.length,
                            onClose: widget.controller.closePlayer,
                          ),
                        ),
                      ),
                    ),
                    if (images.length > 1)
                      Positioned(
                        bottom: 88,
                        left: 0,
                        right: 0,
                        height: 64,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          itemCount: images.length,
                          itemBuilder: (context, index) {
                            final item = images[index];
                            final selected = index == _currentIndex;
                            return GestureDetector(
                              onTap: () {
                                _pageController.animateToPage(
                                  index,
                                  duration: const Duration(milliseconds: 280),
                                  curve: Curves.easeOut,
                                );
                              },
                              child: Container(
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: selected
                                        ? mediaGold
                                        : Colors.white24,
                                    width: selected ? 2 : 1,
                                  ),
                                ),
                                child: MediaThumb(
                                  url: item.thumbnail,
                                  filePath: item.filePath,
                                  width: 52,
                                  height: 52,
                                  radius: 6,
                                ),
                              ),
                            );
                          },
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
                              Colors.black.withValues(alpha: 0.85),
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
                              _GalleryAction(
                                icon: Icons.save_alt,
                                label: 'Save',
                                onTap: () => widget.controller
                                    .saveImageExternally(_currentItem),
                              ),
                              _GalleryAction(
                                icon: Icons.share,
                                label: 'Share',
                                onTap: () => widget.controller
                                    .shareDownload(_currentItem),
                              ),
                              _GalleryAction(
                                icon: _currentItem.favorite
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                label: _currentItem.favorite
                                    ? 'Favorited'
                                    : 'Favorite',
                                color: _currentItem.favorite ? mediaDanger : null,
                                onTap: () => widget.controller
                                    .toggleFavorite(_currentItem),
                              ),
                              _GalleryAction(
                                icon: Icons.delete_outline,
                                label: 'Delete',
                                onTap: () {
                                  widget.controller.closePlayer();
                                  widget.controller
                                      .deleteDownload(_currentItem);
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

class _GalleryHeader extends StatelessWidget {
  const _GalleryHeader({
    required this.title,
    required this.index,
    required this.total,
    required this.onClose,
  });

  final String title;
  final int index;
  final int total;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            onPressed: onClose,
            icon: Icon(Icons.keyboard_return, color: mediaWarmGold, size: 30),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (total > 1)
                  Text(
                    '${index + 1} / $total',
                    style: TextStyle(color: mediaWarmGold, fontSize: 12),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GalleryAction extends StatelessWidget {
  const _GalleryAction({
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
