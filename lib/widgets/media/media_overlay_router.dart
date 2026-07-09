import 'package:flutter/material.dart';

import '../../models/download_models.dart';
import '../../state/downloads_controller.dart';
import 'duck_image_gallery.dart';
import 'duck_player_overlay.dart';

class MediaOverlayRouter extends StatelessWidget {
  const MediaOverlayRouter({
    super.key,
    required this.controller,
    this.galleryItems,
  });

  final DuckDownloadsController controller;
  final List<DownloadItem>? galleryItems;

  @override
  Widget build(BuildContext context) {
    final item = controller.playerItem;
    if (item == null) return const SizedBox.shrink();

    Widget child;
    if (item.isImage) {
      final images = controller.playerGalleryItems ??
          galleryItems ??
          (item.isPrivate
              ? controller.privateDownloads.where((d) => d.isImage).toList()
              : controller.images);
      child = DuckImageGallery(
        item: item,
        allImages: images,
        controller: controller,
      );
    } else {
      child = DuckPlayerOverlay(item: item, controller: controller);
    }

    return SwipeBackWrapper(
      controller: controller,
      child: child,
    );
  }
}

class SwipeBackWrapper extends StatefulWidget {
  const SwipeBackWrapper({
    super.key,
    required this.child,
    required this.controller,
  });

  final Widget child;
  final DuckDownloadsController controller;

  @override
  State<SwipeBackWrapper> createState() => _SwipeBackWrapperState();
}

class _SwipeBackWrapperState extends State<SwipeBackWrapper>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  double _dragOffset = 0.0;
  bool _isDragging = false;
  double _startX = 0.0;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    )..addListener(() {
        setState(() {
          _dragOffset = _animController.value;
        });
      });
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (event.position.dx <= 36.0) {
      _animController.stop();
      _startX = event.position.dx;
      setState(() {
        _isDragging = true;
        _dragOffset = 0.0;
      });
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (!_isDragging) return;
    final deltaX = event.position.dx - _startX;
    setState(() {
      _dragOffset = deltaX.clamp(0.0, double.infinity);
    });
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (!_isDragging) return;
    _isDragging = false;

    if (_dragOffset > 120.0) {
      widget.controller.closePlayer();
    } else {
      _animController.value = _dragOffset;
      _animController.animateTo(0.0, curve: Curves.easeOutCubic);
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (!_isDragging) return;
    _isDragging = false;
    _animController.value = _dragOffset;
    _animController.animateTo(0.0, curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final backdropOpacity = (0.6 * (1.0 - (_dragOffset / screenWidth))).clamp(0.0, 0.6);

    return Listener(
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerUp,
      onPointerCancel: _handlePointerCancel,
      behavior: HitTestBehavior.translucent,
      child: Stack(
        children: [
          if (_dragOffset > 0)
            Positioned.fill(
              child: Container(
                color: Colors.black.withOpacity(backdropOpacity),
              ),
            ),
          Transform.translate(
            offset: Offset(_dragOffset, 0),
            child: AbsorbPointer(
              absorbing: _isDragging,
              child: widget.child,
            ),
          ),
        ],
      ),
    );
  }
}

