import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';

import '../../models/download_models.dart';
import '../../services/trim_service.dart';
import '../../state/downloads_controller.dart';
import 'audio_progress.dart';
import 'media_colors.dart';
import 'media_thumb.dart';
import 'media_utils.dart';
import 'media_slider.dart';
import 'player_error.dart';
class DuckPlayerOverlay extends StatefulWidget {
  const DuckPlayerOverlay({
    super.key,
    required this.item,
    required this.controller,
  });

  final DownloadItem item;
  final DuckDownloadsController controller;

  @override
  State<DuckPlayerOverlay> createState() => _DuckPlayerOverlayState();
}

class _DuckPlayerOverlayState extends State<DuckPlayerOverlay>
    with SingleTickerProviderStateMixin {
  VideoPlayerController? _video;
  String? _error;
  BoxFit _videoFit = BoxFit.contain;
  bool _muted = false;
  double _speed = 1;
  static const _channel = MethodChannel('duck_downloader/media');
  bool _showControls = true;
  Timer? _hideTimer;
  bool _isInPiP = false;
  late final AnimationController _discRotationController;

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

  Duration get _mediaDuration {
    if (widget.item.isVideo) {
      return _video?.value.duration ?? Duration.zero;
    }
    return widget.controller.audioPlayer.duration ?? Duration.zero;
  }

  bool get _canSaveTrim {
    final duration = _mediaDuration;
    if (duration <= Duration.zero) return false;
    return _trimEnd - _trimStart >= TrimService.minClipSeconds;
  }

  static const _compactIconConstraints = BoxConstraints(
    minWidth: 40,
    minHeight: 40,
  );

  Widget _fittedControlRow({
    required List<Widget> children,
    MainAxisAlignment alignment = MainAxisAlignment.spaceEvenly,
  }) {
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: alignment,
            children: children,
          ),
        ),
      ),
    );
  }

  Widget _fittedToolbar({
    required Widget child,
    Alignment alignment = Alignment.centerLeft,
  }) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: alignment,
      child: child,
    );
  }

  @override
  void initState() {
    super.initState();
    _discRotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 18),
    );
    widget.controller.addListener(_syncDiscRotation);
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
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      _video = VideoPlayerController.file(File(filePath))
        ..initialize()
            .then((_) async {
              if (!mounted) return;
              _video?.setPlaybackSpeed(_speed);
              _video?.addListener(_videoListener);
              final resume = widget.controller.videoResumePosition(widget.item.id);
              if (resume > Duration.zero) {
                await _video?.seekTo(resume);
              }
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
          _syncDiscRotation();
        });
      } else {
        _trimStart = 0.0;
        _trimEnd = (widget.controller.audioPlayer.duration ?? Duration.zero)
            .inSeconds
            .toDouble();
        _syncDiscRotation();
      }
    }
  }

  void _syncDiscRotation() {
    if (!widget.item.isAudio || !mounted) return;
    final playing = widget.controller.audioPlayer.playing;
    if (playing) {
      if (!_discRotationController.isAnimating) {
        _discRotationController.repeat();
      }
    } else {
      _discRotationController.stop();
    }
  }

  void _videoListener() {
    final video = _video;
    if (video == null) return;
    final isPlaying = video.value.isPlaying;
    _channel.invokeMethod('setVideoPlaying', {'playing': isPlaying});
    widget.controller.saveVideoResumePosition(
      widget.item.id,
      video.value.position,
    );
    if (mounted) setState(() {});
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
    widget.controller.removeListener(_syncDiscRotation);
    _discRotationController.dispose();
    if (widget.item.isVideo) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    }
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
                  PlayerHeader(
                    item: widget.item,
                    onClose: widget.controller.closePlayer,
                  ),
                  const SizedBox(height: 12),
                  PlayerError(
                    message: _error!,
                    onDelete: () =>
                        widget.controller.deleteDownload(widget.item),
                    onDismiss: () => setState(() => _error = null),
                    onRetry: widget.item.isVideo ? _retryVideo : null,
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
                  PlayerHeader(
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
          child: Center(child: CircularProgressIndicator(color: mediaGold)),
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
            if (value.isBuffering)
              Positioned.fill(
                child: Center(
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: CircularProgressIndicator(
                      color: mediaGold,
                      strokeWidth: 3,
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
                                      color: mediaWarmGold,
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
                                  if (Platform.isAndroid)
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
                      _fittedControlRow(
                        children: [
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: _compactIconConstraints,
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
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.black38,
                              fixedSize: const Size(64, 64),
                            ),
                            icon: Icon(
                              isCompleted
                                  ? Icons.replay
                                  : value.isPlaying
                                  ? Icons.pause
                                  : Icons.play_arrow,
                              size: 40,
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
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: _compactIconConstraints,
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
                                        return MediaSlider(
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
                                    Expanded(
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: _fittedToolbar(
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              IconButton(
                                                visualDensity:
                                                    VisualDensity.compact,
                                                padding: EdgeInsets.zero,
                                                constraints:
                                                    _compactIconConstraints,
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
                                                visualDensity:
                                                    VisualDensity.compact,
                                                padding: EdgeInsets.zero,
                                                constraints:
                                                    _compactIconConstraints,
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
                                              const SizedBox(width: 4),
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
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                    horizontal: 10,
                                                    vertical: 4,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: Colors.white
                                                        .withValues(alpha: 0.08),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                      12,
                                                    ),
                                                  ),
                                                  child: Text(
                                                    '${_speed.toStringAsFixed(_speed == _speed.roundToDouble() ? 0 : 2)}x',
                                                    style: TextStyle(
                                                      color: mediaGold,
                                                      fontWeight: FontWeight.bold,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 4),
                                              if (!kIsWeb)
                                                IconButton(
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  padding: EdgeInsets.zero,
                                                  constraints:
                                                      _compactIconConstraints,
                                                  tooltip: 'Trim video',
                                                  icon: const Icon(
                                                    Icons.content_cut,
                                                    color: Colors.white,
                                                  ),
                                                  onPressed:
                                                      value.duration <=
                                                              Duration.zero
                                                          ? null
                                                          : () {
                                                              setState(() {
                                                                _isTrimmingMode =
                                                                    true;
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
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      padding: EdgeInsets.zero,
                                      constraints: _compactIconConstraints,
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
                                    Expanded(
                                      child: Align(
                                        alignment: Alignment.centerRight,
                                        child: _fittedToolbar(
                                          alignment: Alignment.centerRight,
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
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
                                              const SizedBox(width: 8),
                                              _isSavingTrim
                                                  ? SizedBox(
                                                      width: 20,
                                                      height: 20,
                                                      child:
                                                          CircularProgressIndicator(
                                                        color: mediaGold,
                                                        strokeWidth: 2,
                                                      ),
                                                    )
                                                  : TextButton(
                                                      onPressed: _canSaveTrim
                                                          ? _performTrim
                                                          : null,
                                                      child: Text(
                                                        'Save Trim',
                                                        style: TextStyle(
                                                          color: mediaGold,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                        ),
                                                      ),
                                                    ),
                                            ],
                                          ),
                                        ),
                                      ),
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
                              color: mediaGold.withValues(alpha: 0.15),
                              blurRadius: 40 * scale,
                              spreadRadius: 8 * scale,
                            ),
                          ],
                        ),
                        child: RotationTransition(
                          turns: _discRotationController,
                          child: ClipOval(
                            child: MediaThumb(
                              url: widget.item.thumbnail,
                              preferNetworkThumbnail: true,
                              width: diskSize,
                              height: diskSize,
                              icon: Icons.music_note,
                            ),
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
                            color: mediaWarmGold,
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
                                  color: mediaWarmGold,
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
                      _fittedControlRow(
                        children: [
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: _compactIconConstraints,
                            icon: Icon(
                              widget.controller.shuffleEnabled
                                  ? Icons.shuffle
                                  : Icons.shuffle_outlined,
                              size: 26,
                              color: widget.controller.shuffleEnabled
                                  ? mediaGold
                                  : Colors.white70,
                            ),
                            onPressed: widget.controller.toggleShuffle,
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: _compactIconConstraints,
                            icon: Icon(
                              widget.controller.hasPreviousTrack
                                  ? Icons.skip_previous
                                  : Icons.skip_previous_outlined,
                              size: 36,
                              color: widget.controller.hasPreviousTrack
                                  ? Colors.white
                                  : Colors.white38,
                            ),
                            onPressed: widget.controller.hasPreviousTrack
                                ? widget.controller.playPrevious
                                : null,
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: _compactIconConstraints,
                            icon: const Icon(
                              Icons.replay_10,
                              size: 42,
                              color: Colors.white,
                            ),
                            onPressed: () {
                              _resetHideTimer();
                              _seekAudio(const Duration(seconds: -10));
                            },
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.black38,
                              fixedSize: const Size(64, 64),
                            ),
                            icon: Icon(
                              isCompleted
                                  ? Icons.replay
                                  : playing
                                  ? Icons.pause
                                  : Icons.play_arrow,
                              size: 40,
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
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: _compactIconConstraints,
                            icon: const Icon(
                              Icons.forward_10,
                              size: 42,
                              color: Colors.white,
                            ),
                            onPressed: () {
                              _resetHideTimer();
                              _seekAudio(const Duration(seconds: 10));
                            },
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: _compactIconConstraints,
                            icon: Icon(
                              widget.controller.hasNextTrack
                                  ? Icons.skip_next
                                  : Icons.skip_next_outlined,
                              size: 36,
                              color: widget.controller.hasNextTrack
                                  ? Colors.white
                                  : Colors.white38,
                            ),
                            onPressed: widget.controller.hasNextTrack
                                ? widget.controller.playNext
                                : null,
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: _compactIconConstraints,
                            icon: Icon(
                              switch (widget.controller.loopMode) {
                                LoopMode.one => Icons.repeat_one,
                                LoopMode.all => Icons.repeat,
                                LoopMode.off => Icons.repeat_outlined,
                              },
                              size: 26,
                              color: widget.controller.loopMode == LoopMode.off
                                  ? Colors.white70
                                  : mediaGold,
                            ),
                            onPressed: widget.controller.toggleLoopMode,
                          ),
                        ],
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
                                AudioProgress(
                                  player: audio,
                                  onSeek: (pos) {
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
                                    Expanded(
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: _fittedToolbar(
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
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
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                    horizontal: 10,
                                                    vertical: 4,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: Colors.white
                                                        .withValues(alpha: 0.08),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                      12,
                                                    ),
                                                  ),
                                                  child: Text(
                                                    '${_speed.toStringAsFixed(_speed == _speed.roundToDouble() ? 0 : 2)}x',
                                                    style: TextStyle(
                                                      color: mediaGold,
                                                      fontWeight: FontWeight.bold,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 4),
                                              if (!kIsWeb)
                                                IconButton(
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  padding: EdgeInsets.zero,
                                                  constraints:
                                                      _compactIconConstraints,
                                                  tooltip: 'Trim audio',
                                                  icon: const Icon(
                                                    Icons.content_cut,
                                                    color: Colors.white,
                                                  ),
                                                  onPressed:
                                                      duration <= Duration.zero
                                                          ? null
                                                          : () {
                                                              setState(() {
                                                                _isTrimmingMode =
                                                                    true;
                                                                _trimStart = 0.0;
                                                                _trimEnd = duration
                                                                    .inSeconds
                                                                    .toDouble();
                                                              });
                                                            },
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      padding: EdgeInsets.zero,
                                      constraints: _compactIconConstraints,
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
                                    Expanded(
                                      child: Align(
                                        alignment: Alignment.centerRight,
                                        child: _fittedToolbar(
                                          alignment: Alignment.centerRight,
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
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
                                              const SizedBox(width: 8),
                                              _isSavingTrim
                                                  ? SizedBox(
                                                      width: 20,
                                                      height: 20,
                                                      child:
                                                          CircularProgressIndicator(
                                                        color: mediaGold,
                                                        strokeWidth: 2,
                                                      ),
                                                    )
                                                  : TextButton(
                                                      onPressed: _canSaveTrim
                                                          ? _performTrim
                                                          : null,
                                                      child: Text(
                                                        'Save Trim',
                                                        style: TextStyle(
                                                          color: mediaGold,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                        ),
                                                      ),
                                                    ),
                                            ],
                                          ),
                                        ),
                                      ),
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
          activeColor: mediaGold,
          inactiveColor: Colors.white24,
          onChanged: duration <= Duration.zero
              ? null
              : (RangeValues val) {
                  setState(() {
                    _trimStart = val.start;
                    _trimEnd = val.end;
                  });
                },
          onChangeEnd: duration <= Duration.zero
              ? null
              : (RangeValues val) => unawaited(_previewTrimStart(val.start)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                formatMediaDuration(Duration(seconds: currentStart.toInt())),
                style: TextStyle(
                  color: mediaGold,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                formatMediaDuration(Duration(seconds: currentEnd.toInt())),
                style: TextStyle(
                  color: mediaGold,
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

  Future<void> _previewTrimStart(double startSec) async {
    final target = Duration(milliseconds: (startSec * 1000).round());
    if (widget.item.isVideo) {
      final video = _video;
      if (video == null || !video.value.isInitialized) return;
      await video.seekTo(target);
    } else {
      await widget.controller.audioPlayer.seek(target);
    }
  }

  Future<void> _reloadVideoFromDisk() async {
    final path = widget.controller.playerItem?.filePath ?? widget.item.filePath;
    if (path == null || !widget.item.isVideo) return;
    await _video?.dispose();
    _video = VideoPlayerController.file(File(path))
      ..initialize().then((_) async {
        if (!mounted) return;
        _video?.setPlaybackSpeed(_speed);
        _video?.addListener(_videoListener);
        setState(() {
          _trimStart = 0.0;
          _trimEnd = _video!.value.duration.inSeconds.toDouble();
          _isTrimmingMode = false;
        });
        await _video?.play();
      });
  }

  Future<void> _performTrim() async {
    if (!_canSaveTrim) return;
    setState(() => _isSavingTrim = true);
    try {
      await widget.controller.trimDownload(
        widget.controller.playerItem ?? widget.item,
        startTime: _trimStart,
        endTime: _trimEnd,
        totalDuration: _mediaDuration,
      );
      if (!mounted) return;
      setState(() {
        _isSavingTrim = false;
        _isTrimmingMode = false;
      });
      if (widget.item.isVideo) {
        await _reloadVideoFromDisk();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _isSavingTrim = false;
      });
    }
  }

  Future<void> _seekVideo(Duration delta) async {
    final video = _video;
    if (video == null) return;
    final next = video.value.position + delta;
    await video.seekTo(clampMediaDuration(next, video.value.duration));
  }

  Future<void> _seekAudio(Duration delta) async {
    final audio = widget.controller.audioPlayer;
    final next = audio.position + delta;
    await audio.seek(clampMediaDuration(next, audio.duration ?? Duration.zero));
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

  Future<void> _retryVideo() async {
    final filePath = widget.item.filePath;
    if (filePath == null) return;
    setState(() => _error = null);
    _video?.dispose();
    _video = VideoPlayerController.file(File(filePath))
      ..initialize()
          .then((_) async {
            if (!mounted) return;
            _video?.setPlaybackSpeed(_speed);
            _video?.addListener(_videoListener);
            setState(() {
              _trimStart = 0.0;
              _trimEnd = _video!.value.duration.inSeconds.toDouble();
            });
            await _video?.play();
            _startHideTimer();
          })
          .catchError((Object _) {
            if (mounted) {
              setState(() => _error = 'This file could not be played.');
            }
          });
  }
}

class PlayerHeader extends StatelessWidget {
  const PlayerHeader({super.key, required this.item, required this.onClose});

  final DownloadItem item;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          onPressed: onClose,
          icon: Icon(Icons.keyboard_return, color: mediaWarmGold, size: 34),
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


