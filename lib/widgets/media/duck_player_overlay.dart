import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/duck_media_channel.dart';
import '../../models/download_models.dart';
import '../../services/trim_service.dart';
import '../../state/downloads_controller.dart';
import '../../services/vault_encryption_service.dart';
import 'media_colors.dart';
import 'media_thumb.dart';
import 'media_utils.dart';
import 'media_slider.dart';
import 'liquid_interactive_button.dart';
import '../../theme/duck_theme.dart';
import '../duck_liquid_glass.dart';
import 'animated_favorite_button.dart';
import 'player_error.dart';
import 'audio_queue_sheet.dart';
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
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  VideoPlayerController? _video;
  String? _error;
  BoxFit _videoFit = BoxFit.contain;
  bool _muted = false;
  double _speed = 1;
  static const _channel = MethodChannel('duck_downloader/media');
  bool _showControls = true;
  Timer? _hideTimer;
  bool _isInPiP = false;

  /// Set by the platform right before it enters PiP, so the lifecycle event
  /// that follows does not also hand audio to the background player.
  bool _enteringPip = false;
  bool _backgroundHandoffActive = false;
  Duration _savedPositionForHandoff = Duration.zero;
  late final AnimationController _discRotationController;

  // Double-tap seek overlays
  bool _showLeftSeekIndicator = false;
  bool _showRightSeekIndicator = false;
  Timer? _leftSeekTimer;
  Timer? _rightSeekTimer;

  // Center play/pause overlays
  bool _showCenterPlayIndicator = false;
  bool _showCenterPauseIndicator = false;

  bool _showSpeedPanel = false;
  Timer? _centerPlayPauseTimer;

  // Aspect ratio fit toast overlay
  String? _fitLabel;
  Timer? _fitLabelTimer;

  // Trimming fields
  bool _isTrimmingMode = false;
  double _trimStart = 0.0;
  double _trimEnd = 1.0;
  bool _isSavingTrim = false;

  // VLC Gesture Control State
  double _brightness = 1.0;
  double _swipeStartVolume = 1.0;
  double _swipeStartBrightness = 1.0;
  Duration _swipeStartDuration = Duration.zero;

  bool _isSwiping = false;
  String _swipeType = ''; // 'volume' | 'brightness' | 'seek'
  bool _isScreenLocked = false;
  bool _showUnlockButton = false;
  Timer? _unlockButtonTimer;

  void _resetUnlockButtonTimer() {
    _unlockButtonTimer?.cancel();
    _unlockButtonTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() {
          _showUnlockButton = false;
        });
      }
    });
  }
  bool _showUpNext = false;
  Timer? _upNextTimer;
  int _upNextCountdown = 10;
  bool _upNextCancelled = false;
  bool _isLooping = false;
  double _swipeDisplayValue = 0.0; // percentage or duration seconds
  Timer? _swipeFeedbackTimer;
  Offset _panStartOffset = Offset.zero;
  String _panDirection = ''; // 'horizontal' | 'vertical' | ''

  String? _lastAudioItemId;
  AppLifecycleState _currentLifecycleState = AppLifecycleState.resumed;
  bool _showGifPanel = false;
  bool _showSleepTimerPanel = false;
  bool _showVideoMorePanel = false;
  bool _showQueuePanel = false;
  double _gifStartTime = 0.0;
  double _gifDuration = 5.0;
  int _gifWidth = 320;
  bool _isSavingGif = false;
  bool _is2xSpeedLocked = false;
  bool _isLongPress2xActive = false;
  double _longPressStartY = 0.0;
  bool _hasSwipedToLockDuringPress = false;

  void _unlock2xSpeed() {
    _video?.setPlaybackSpeed(1.0);
    setState(() {
      _is2xSpeedLocked = false;
      _isLongPress2xActive = false;
    });
  }

  Duration _cachedAudioDuration = Duration.zero;
  Duration? _draggedAudioPosition;

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _discRotationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
      value: widget.controller.audioPlayer.playing ? 1.0 : 0.0,
    );
    widget.controller.addListener(_syncDiscRotation);
    widget.controller.addBackInterceptor(_handleBack);
    DuckMediaChannel.instance.addHandler(_handleNativeCall);

    final filePath = widget.item.filePath;
    if (filePath == null) return;
    if (widget.item.isVideo) {
      widget.controller.buildVideoQueue(widget.item);
      // Greys out Next/Previous in the PiP window when the queue has no more
      // items in that direction.
      _syncPiPQueueState();
      _video = VideoPlayerController.file(File(filePath))
        ..initialize()
            .then((_) async {
              if (!mounted) return;
              
              // Keep screen awake
              WakelockPlus.enable();

              // Dynamic orientation based on video aspect ratio
              final aspect = _video?.value.aspectRatio ?? 1.0;
              if (aspect > 1.1) {
                SystemChrome.setPreferredOrientations([
                  DeviceOrientation.landscapeLeft,
                  DeviceOrientation.landscapeRight,
                ]);
              } else {
                SystemChrome.setPreferredOrientations([
                  DeviceOrientation.portraitUp,
                ]);
              }

              _video?.setPlaybackSpeed(_speed);
              _video?.addListener(_videoListener);
              var resume = widget.controller.videoResumePosition(widget.item.id);
              if (widget.controller.isBackgroundVideoActive &&
                  widget.controller.playingItem?.id == widget.item.id) {
                resume = widget.controller.audioPlayer.position;
                await widget.controller.stopBackgroundVideoAudio();
              }
              if (resume > Duration.zero) {
                await _video?.seekTo(resume);
              }
              setState(() {
                _trimStart = 0.0;
                _trimEnd = _video!.value.duration.inSeconds.toDouble();
              });
              _video?.play();
              _startHideTimer();

              // ── Pre-load background audio at volume 0 ──────────────────
              // So locking the screen only has to unmute — no loading delay.
              // Unconditional: background playback is how the player behaves,
              // not a mode the user opts into.
              unawaited(widget.controller.preloadBackgroundAudio(widget.item));
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
      _discRotationController.forward();
    } else {
      _discRotationController.reverse();
    }
    setState(() {});
  }

  /// What the user last asked the video to do, as opposed to what the platform
  /// player currently reports — the two diverge the moment the screen turns off.
  bool _wasPlayingBeforeBackground = false;

  void _videoListener() {
    final video = _video;
    if (video == null) return;
    final isPlaying = video.value.isPlaying;
    // Only record the transition while the app is actually on screen: once it
    // is backgrounded the platform reports a pause that the user never asked
    // for, and latching that would defeat the handoff.
    if (_currentLifecycleState == AppLifecycleState.resumed) {
      _wasPlayingBeforeBackground = isPlaying;
    }
    try {
      _channel.invokeMethod('setVideoPlaying', {'playing': isPlaying});
    } catch (_) {}
    widget.controller.saveVideoResumePosition(
      widget.item.id,
      video.value.position,
    );
    // Re-apply speed on Android every time the video starts playing
    // (Android may reset speed after seek/buffer events)
    if (isPlaying && _speed != 1.0) {
      video.setPlaybackSpeed(_speed);
    }
    
    final value = video.value;
    if (value.isInitialized && widget.controller.hasNextVideo && !_isLooping && !_upNextCancelled) {
      final remaining = value.duration - value.position;
      if (remaining.inSeconds <= 15 && !_showUpNext) {
        _showUpNext = true;
        _upNextCountdown = 10;
        _upNextTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          if (!mounted) {
            timer.cancel();
            return;
          }
          setState(() {
            if (_upNextCountdown > 0) {
              _upNextCountdown--;
            } else {
              timer.cancel();
              _showUpNext = false;
              widget.controller.playNextVideo();
            }
          });
        });
      } else if (remaining.inSeconds > 15 && _showUpNext) {
        _showUpNext = false;
        _upNextTimer?.cancel();
      }
    }
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
    } on PlatformException catch (e) {
      if (e.code == 'pip_not_supported' && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Picture-in-Picture is not supported on this device.'),
            duration: Duration(seconds: 2),
          ),
        );
      } else {
        debugPrint('Failed to enter PiP mode: $e');
      }
    } catch (e) {
      debugPrint('Failed to enter PiP mode: $e');
    }
  }

  /// Platform events for the open player.
  ///
  /// Shared with the rest of the app through [DuckMediaChannel]: a plain
  /// `setMethodCallHandler` here would have replaced the controller's
  /// quick-share listener for as long as a video was open, then removed it
  /// entirely on close.
  Future<void> _handleNativeCall(MethodCall call) async {
    if (!mounted) return;

    switch (call.method) {
      case 'pipModeChanged':
        final inPiP = call.arguments as bool;
        setState(() {
          _isInPiP = inPiP;
          _showControls = !inPiP;
        });

      case 'pipAction':
        // Ids mirror MainActivity.PipAction.
        switch (call.arguments as int) {
          case 1:
            _video?.play();
          case 2:
            _video?.pause();
          case 3:
            widget.controller.playNextVideo();
          case 4:
            widget.controller.playPreviousVideo();
        }

      case 'enteringPip':
        // Arrives just before the activity enters PiP, so the lifecycle event
        // that follows knows not to start a background handoff that would
        // fight the PiP window.
        _enteringPip = true;

      case 'pipDismissed':
        // Closed with the X rather than expanded back. Keep the sound going
        // instead of stopping dead.
        _enteringPip = false;
        unawaited(_handoffVideoAudioToBackground());

      case 'screenOff':
        debugPrint(
          'BG AUDIO: screenOff — isVideo=${widget.item.isVideo} '
          'inPiP=$_isInPiP wasPlaying=$_wasPlayingBeforeBackground',
        );
        // Power button. Unambiguous and immediate — no waiting to see whether
        // PiP was going to happen.
        if (widget.item.isVideo && !_isInPiP) {
          unawaited(_handoffVideoAudioToBackground());
        }

      case 'screenOn':
        if (widget.item.isVideo && _backgroundHandoffActive) {
          unawaited(_resumeVideoFromBackground());
        }
    }
  }

  /// Authoritative PiP check, straight from the activity.
  ///
  /// `_isInPiP` comes from the `pipModeChanged` callback, which races the
  /// lifecycle event; losing that race paused the video and started a second
  /// player, leaving a frozen PiP window with sound from somewhere else.
  Future<bool> _isInPiPNow() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isInPiP') ?? _isInPiP;
    } catch (_) {
      return _isInPiP;
    }
  }

  /// Mirrors the video queue into the PiP window's Next / Previous buttons.
  void _syncPiPQueueState() {
    if (!Platform.isAndroid || !widget.item.isVideo) return;
    try {
      _channel.invokeMethod('setVideoQueueState', {
        'hasNext': widget.controller.hasNextVideo,
        'hasPrevious': widget.controller.hasPreviousVideo,
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_syncDiscRotation);
    widget.controller.removeBackInterceptor(_handleBack);
    _discRotationController.dispose();
    if (widget.item.isVideo) {
      WakelockPlus.disable();
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      // Fully release background audio when the player closes.
      unawaited(widget.controller.stopBackgroundVideoAudio());
    }
    unawaited(VaultEncryptionService.cleanVaultTempFiles());
    _hideTimer?.cancel();
    _leftSeekTimer?.cancel();
    _rightSeekTimer?.cancel();
    _centerPlayPauseTimer?.cancel();
    _fitLabelTimer?.cancel();
    _upNextTimer?.cancel();
    _unlockButtonTimer?.cancel();
    _video?.removeListener(_videoListener);
    try {
      _channel.invokeMethod('setVideoPlaying', {'playing': false});
    } catch (_) {}
    DuckMediaChannel.instance.removeHandler(_handleNativeCall);
    _video?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    super.didChangeAppLifecycleState(state);
    _currentLifecycleState = state;

    if (!widget.item.isVideo) return;

    // The two cases that matter — locking the screen and entering PiP — are
    // now reported explicitly by the platform (`screenOff` / `enteringPip`),
    // so this only covers what is left: the app being backgrounded without PiP
    // taking over. `paused` rather than `inactive`, because a rotation raises
    // `inactive` and immediately returns, which is what the old 350ms sleep
    // was there to filter out.
    if (state == AppLifecycleState.paused) {
      if (_enteringPip || _isInPiP) return;
      if (await _isInPiPNow()) return;

      await _handoffVideoAudioToBackground();
    } else if (state == AppLifecycleState.resumed) {
      _enteringPip = false;
      await _resumeVideoFromBackground();
    }
  }

  /// Screen lock: seek pre-loaded audio to exact video position, unmute,
  /// then pause the video. The audio is already loaded so this is ~instant.
  Future<void> _handoffVideoAudioToBackground() async {
    if (_isInPiP) return;
    final video = _video;
    if (video == null || !video.value.isInitialized) return;
    if (_backgroundHandoffActive) return;

    // Deliberately *not* `video.value.isPlaying`. Turning the screen off
    // destroys the render surface, and the platform player reports itself as
    // paused before this handler gets a chance to run — so reading it here
    // aborted the handoff on exactly the case it exists for. `_wasPlaying` is
    // tracked continuously from the video listener instead, which records what
    // the user actually asked for.
    if (!_wasPlayingBeforeBackground) return;

    _backgroundHandoffActive = true;
    _savedPositionForHandoff = video.value.position;
    widget.controller.saveVideoResumePosition(widget.item.id, _savedPositionForHandoff);

    // Activate pre-loaded audio: seek + unmute + play (nearly instant)
    await widget.controller.ensureAndActivateBackgroundAudio(widget.item, _savedPositionForHandoff);

    // Now pause the video — audio is already playing from background player
    video.pause();
  }

  /// Screen unlock: resume video from background audio position, then mute
  /// the background audio (keeps it loaded for next lock).
  Future<void> _resumeVideoFromBackground() async {
    if (!_backgroundHandoffActive) return;
    _backgroundHandoffActive = false;

    var currentPos = widget.controller.audioPlayer.position;
    if (currentPos <= Duration.zero && _savedPositionForHandoff > Duration.zero) {
      currentPos = _savedPositionForHandoff;
    }
    widget.controller.saveVideoResumePosition(widget.item.id, currentPos);

    final video = _video;
    if (video == null || !mounted || !video.value.isInitialized) {
      await widget.controller.deactivateBackgroundAudio();
      return;
    }

    // Resume video at the exact audio position
    await video.seekTo(currentPos);
    await video.play();

    // Mute + pause background audio (stays loaded for next lock)
    await widget.controller.deactivateBackgroundAudio();

    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return SizedBox.expand(
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
      return SizedBox.expand(
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
      return SizedBox.expand(
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
      return SizedBox.expand(
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

    return SizedBox.expand(
      child: Container(
        color: Colors.black,
        child: Stack(
          children: [
            // Video display area
            Positioned.fill(
              child: GestureDetector(
                onTap: () {
                  if (_isScreenLocked) {
                    setState(() {
                      _showUnlockButton = !_showUnlockButton;
                    });
                    if (_showUnlockButton) {
                      _resetUnlockButtonTimer();
                    }
                  } else {
                    _toggleControls();
                  }
                },
                onDoubleTapDown: !_isScreenLocked ? (details) {
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
                } : null,
                onLongPressStart: !_isScreenLocked ? (details) {
                  final v = _video;
                  if (v != null && v.value.isInitialized) {
                    _longPressStartY = details.globalPosition.dy;
                    _hasSwipedToLockDuringPress = false;
                    setState(() {
                      _isLongPress2xActive = true;
                    });
                    v.setPlaybackSpeed(2.0);
                  }
                } : null,
                onLongPressMoveUpdate: !_isScreenLocked ? (details) {
                  if (_isLongPress2xActive) {
                    final double dy = details.globalPosition.dy - _longPressStartY;
                    if (dy.abs() > 35 && !_hasSwipedToLockDuringPress) {
                      _hasSwipedToLockDuringPress = true;
                      setState(() {
                        _is2xSpeedLocked = !_is2xSpeedLocked;
                      });
                      if (!_is2xSpeedLocked) {
                        _video?.setPlaybackSpeed(1.0);
                        _isLongPress2xActive = false;
                      }
                    }
                  }
                } : null,
                onLongPressEnd: !_isScreenLocked ? (_) {
                  if (_isLongPress2xActive) {
                    if (!_is2xSpeedLocked) {
                      _video?.setPlaybackSpeed(1.0);
                      setState(() {
                        _isLongPress2xActive = false;
                      });
                    } else {
                      setState(() {
                        _isLongPress2xActive = false;
                      });
                    }
                  }
                } : null,
                onPanStart: !_isScreenLocked ? (details) {
                  _isSwiping = true;
                  _swipeFeedbackTimer?.cancel();
                  _panStartOffset = details.localPosition;
                  _swipeStartVolume = video.value.volume;
                  _swipeStartBrightness = _brightness;
                  _swipeStartDuration = video.value.position;
                  _panDirection = '';
                  _swipeType = '';
                  setState(() {});
                } : null,
                onPanUpdate: !_isScreenLocked ? (details) {
                  if (!_isSwiping) return;
                  final screenWidth = MediaQuery.sizeOf(context).width;
                  final screenHeight = MediaQuery.sizeOf(context).height;
                  final dx = details.localPosition.dx - _panStartOffset.dx;
                  final dy = details.localPosition.dy - _panStartOffset.dy;

                  if (_panDirection.isEmpty) {
                    if (dx.abs() > 15) {
                      _panDirection = 'horizontal';
                      _swipeType = 'seek';
                    } else if (dy.abs() > 15) {
                      _panDirection = 'vertical';
                      if (_panStartOffset.dx < screenWidth / 2) {
                        _swipeType = 'brightness';
                      } else {
                        _swipeType = 'volume';
                      }
                    }
                  }

                  if (_panDirection == 'vertical') {
                    final double deltaY = -dy / screenHeight;
                    if (_swipeType == 'volume') {
                      final nextVolume = (_swipeStartVolume + deltaY * 1.5).clamp(0.0, 1.0);
                      video.setVolume(nextVolume);
                      setState(() {
                        _swipeDisplayValue = nextVolume;
                      });
                    } else if (_swipeType == 'brightness') {
                      final nextBrightness = (_swipeStartBrightness + deltaY * 1.5).clamp(0.0, 1.0);
                      setState(() {
                        _brightness = nextBrightness;
                        _swipeDisplayValue = nextBrightness;
                      });
                    }
                  } else if (_panDirection == 'horizontal') {
                    final double deltaX = dx / screenWidth;
                    final seekDelta = Duration(seconds: (deltaX * 120).toInt());
                    final targetPosition = _swipeStartDuration + seekDelta;
                    final duration = video.value.duration;
                    final finalPosition = targetPosition < Duration.zero
                        ? Duration.zero
                        : (targetPosition > duration ? duration : targetPosition);
                    setState(() {
                      _swipeDisplayValue = finalPosition.inSeconds.toDouble();
                    });
                  }
                } : null,
                onPanEnd: !_isScreenLocked ? (_) {
                  if (_swipeType == 'seek') {
                    video.seekTo(Duration(seconds: _swipeDisplayValue.toInt()));
                  }
                  _isSwiping = false;
                  _swipeFeedbackTimer?.cancel();
                  _swipeFeedbackTimer = Timer(const Duration(milliseconds: 800), () {
                    setState(() {
                      _swipeType = '';
                    });
                  });
                } : null,
                behavior: HitTestBehavior.opaque,
                child: ClipRect(
                  child: SizedBox.expand(
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
            ),

            // Simulated Brightness Layer
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Colors.black.withOpacity((1.0 - _brightness).clamp(0.0, 0.95)),
                ),
              ),
            ),

            // Swipe Gestures HUD
            if (_swipeType.isNotEmpty)
              Center(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.75),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white10),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _swipeType == 'volume'
                            ? (_swipeDisplayValue == 0.0 ? Icons.volume_mute : Icons.volume_up)
                            : _swipeType == 'brightness'
                                ? Icons.brightness_5
                                : Icons.fast_forward,
                        color: mediaGold,
                        size: 24,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        _swipeType == 'volume'
                            ? 'Volume: ${(_swipeDisplayValue * 100).toInt()}%'
                            : _swipeType == 'brightness'
                                ? 'Brightness: ${(_swipeDisplayValue * 100).toInt()}%'
                                : 'Seek: ${formatMediaDuration(Duration(seconds: _swipeDisplayValue.toInt()))}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            if (_isLongPress2xActive || _is2xSpeedLocked)
              Positioned(
                top: 56,
                left: 0,
                right: 0,
                child: Center(
                  child: GestureDetector(
                    onTap: _unlock2xSpeed,
                    child: DuckLiquidGlassSurface(
                      blurSigma: 16,
                      fallbackColor: mediaGold.withValues(alpha: 0.25),
                      fallbackBorderColor: mediaGold.withValues(alpha: 0.6),
                      borderRadius: 20,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _is2xSpeedLocked ? Icons.lock : Icons.fast_forward_rounded,
                              color: mediaGold,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _is2xSpeedLocked ? '2x Speed Locked (Tap/Swipe to Unlock)' : '2x Fast Forward ⏩',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),

            // Buffering Indicator
            if (value.isBuffering)
              const Positioned.fill(
                child: Center(
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: CircularProgressIndicator(
                      color: Colors.white70,
                      strokeWidth: 3,
                    ),
                  ),
                ),
              ),

            // Skip backward visual indicator
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
                    builder: (context, val, child) {
                      return Opacity(
                        opacity: (1.0 - val).clamp(0.0, 1.0),
                        child: Transform.scale(
                          scale: 0.8 + 0.4 * val,
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

            // Skip forward visual indicator
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
                    builder: (context, val, child) {
                      return Opacity(
                        opacity: (1.0 - val).clamp(0.0, 1.0),
                        child: Transform.scale(
                          scale: 0.8 + 0.4 * val,
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

            // Aspect ratio indicator
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

            // Floating Controls Overlay
            AnimatedOpacity(
              opacity: _showControls ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 250),
              child: IgnorePointer(
                ignoring: !_showControls,
                child: Stack(
                  children: [
                    // Top Controls Panel
                    Positioned(
                      top: 16,
                      left: 16,
                      right: 16,
                      child: SafeArea(
                        bottom: false,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: SizedBox(
                            width: MediaQuery.sizeOf(context).width - 32,
                            child: DuckLiquidGlassLayer(
                              settings: DuckLiquidGlass.button(),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _buildCircularGlassButton(
                                        child: const Icon(Icons.close, color: Colors.white, size: 22),
                                        onPressed: widget.controller.closePlayer,
                                        useOwnLayer: false,
                                      ),
                                      const SizedBox(width: 8),
                                      _buildCapsuleGlassContainer(
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            IconButton(
                                              padding: EdgeInsets.zero,
                                              constraints: const BoxConstraints(),
                                              icon: const Icon(Icons.picture_in_picture_alt, color: Colors.white, size: 20),
                                              onPressed: _enterPiP,
                                            ),
                                            const SizedBox(width: 12),
                                            IconButton(
                                              padding: EdgeInsets.zero,
                                              constraints: const BoxConstraints(),
                                              icon: Icon(
                                                _videoFit == BoxFit.contain ? Icons.fullscreen : Icons.fullscreen_exit,
                                                color: Colors.white,
                                                size: 20,
                                              ),
                                              onPressed: _toggleFit,
                                            ),
                                          ],
                                        ),
                                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                        height: 48,
                                        useOwnLayer: false,
                                      ),
                                    ],
                                  ),
                                  _buildCircularGlassButton(
                                    child: Icon(
                                      _muted ? Icons.volume_off : Icons.volume_up,
                                      color: Colors.white,
                                      size: 22,
                                    ),
                                    onPressed: () {
                                      _resetHideTimer();
                                      _toggleMute();
                                    },
                                    useOwnLayer: false,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),

                    // Center Playback Control Row
                    if (!_isTrimmingMode)
                      Builder(
                        builder: (context) {
                          final isLandscape = MediaQuery.orientationOf(context) == Orientation.landscape;
                          final playBtnSize = isLandscape ? 88.0 : 64.0;
                          final playIconSize = isLandscape ? 42.0 : 32.0;
                          final seekBtnSize = isLandscape ? 60.0 : 46.0;
                          final seekIconSize = isLandscape ? 26.0 : 20.0;
                          final skipIconSize = isLandscape ? 30.0 : 24.0;
                          final spacing = isLandscape ? 20.0 : 10.0;

                          return Center(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  icon: Icon(
                                    widget.controller.hasPreviousVideo
                                        ? Icons.skip_previous
                                        : Icons.skip_previous_outlined,
                                    size: skipIconSize,
                                    color: widget.controller.hasPreviousVideo
                                        ? Colors.white
                                        : Colors.white24,
                                  ),
                                  onPressed: widget.controller.hasPreviousVideo
                                      ? () { widget.controller.playPreviousVideo(); }
                                      : null,
                                ),
                                SizedBox(width: spacing),
                                _buildCircularGlassButton(
                                  size: seekBtnSize,
                                  child: Icon(Icons.replay_10, color: Colors.white, size: seekIconSize),
                                  onPressed: () {
                                    _resetHideTimer();
                                    _seekVideo(const Duration(seconds: -10));
                                  },
                                ),
                                SizedBox(width: spacing),
                                _buildCircularGlassButton(
                                  size: playBtnSize,
                                  child: Icon(
                                    isCompleted
                                        ? Icons.replay
                                        : value.isPlaying
                                        ? Icons.pause
                                        : Icons.play_arrow,
                                    color: Colors.white,
                                    size: playIconSize,
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
                                SizedBox(width: spacing),
                                _buildCircularGlassButton(
                                  size: seekBtnSize,
                                  child: Icon(Icons.forward_10, color: Colors.white, size: seekIconSize),
                                  onPressed: () {
                                    _resetHideTimer();
                                    _seekVideo(const Duration(seconds: 10));
                                  },
                                ),
                                SizedBox(width: spacing),
                                IconButton(
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  icon: Icon(
                                    widget.controller.hasNextVideo
                                        ? Icons.skip_next
                                        : Icons.skip_next_outlined,
                                    size: skipIconSize,
                                    color: widget.controller.hasNextVideo
                                        ? Colors.white
                                        : Colors.white24,
                                  ),
                                  onPressed: widget.controller.hasNextVideo
                                      ? () { widget.controller.playNextVideo(); }
                                      : null,
                                ),
                              ],
                            ),
                          );
                        },
                      ),

                    // Bottom Seeker & Options Area
                    Positioned(
                      bottom: 16,
                      left: 16,
                      right: 16,
                      child: SafeArea(
                        top: false,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Auxiliary options row (Speed dial on right, Quick tools + 3 dots on left)
                            if (!_isTrimmingMode)
                              Builder(
                                builder: (context) {
                                  final isLandscape = MediaQuery.orientationOf(context) == Orientation.landscape;
                                  final iconSize = isLandscape ? 20.0 : 17.0;
                                  final spacing = isLandscape ? 12.0 : 5.0;
                                  final capsuleHeight = isLandscape ? 48.0 : 40.0;
                                  final capsulePadding = isLandscape
                                      ? const EdgeInsets.symmetric(horizontal: 12, vertical: 6)
                                      : const EdgeInsets.symmetric(horizontal: 8, vertical: 4);
                                  final btnConstraints = isLandscape
                                      ? const BoxConstraints(minWidth: 32, minHeight: 32)
                                      : const BoxConstraints(minWidth: 24, minHeight: 24);

                                  return Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        _buildCapsuleGlassContainer(
                                          padding: capsulePadding,
                                          height: capsuleHeight,
                                          useOwnLayer: true,
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (!kIsWeb) ...[
                                                IconButton(
                                                  padding: EdgeInsets.zero,
                                                  constraints: btnConstraints,
                                                  icon: Icon(Icons.content_cut, color: Colors.white, size: iconSize),
                                                  onPressed: value.duration <= Duration.zero
                                                      ? null
                                                      : () {
                                                          setState(() {
                                                            _isTrimmingMode = true;
                                                            _trimStart = 0.0;
                                                            _trimEnd = value.duration.inSeconds.toDouble();
                                                          });
                                                        },
                                                ),
                                                SizedBox(width: spacing),
                                                if (widget.item.isVideo) ...[
                                                  IconButton(
                                                    padding: EdgeInsets.zero,
                                                    constraints: btnConstraints,
                                                    icon: Icon(Icons.gif, color: Colors.white, size: iconSize + 3),
                                                    onPressed: value.duration <= Duration.zero
                                                        ? null
                                                        : () => _showGifMakerSheet(context),
                                                  ),
                                                  SizedBox(width: spacing),
                                                  IconButton(
                                                    padding: EdgeInsets.zero,
                                                    constraints: btnConstraints,
                                                    icon: Icon(
                                                      isLandscape
                                                          ? Icons.screen_lock_landscape
                                                          : Icons.screen_lock_portrait,
                                                      color: Colors.white,
                                                      size: iconSize,
                                                    ),
                                                    onPressed: () {
                                                      _resetHideTimer();
                                                      if (isLandscape) {
                                                        SystemChrome.setPreferredOrientations([
                                                          DeviceOrientation.portraitUp,
                                                        ]);
                                                      } else {
                                                        SystemChrome.setPreferredOrientations([
                                                          DeviceOrientation.landscapeLeft,
                                                          DeviceOrientation.landscapeRight,
                                                        ]);
                                                      }
                                                    },
                                                  ),
                                                  SizedBox(width: spacing),
                                                  IconButton(
                                                    padding: EdgeInsets.zero,
                                                    constraints: btnConstraints,
                                                    icon: Icon(Icons.lock_outline, color: Colors.white, size: iconSize),
                                                    onPressed: () {
                                                      HapticFeedback.mediumImpact();
                                                      setState(() {
                                                        _isScreenLocked = true;
                                                        _showControls = false;
                                                        _showUnlockButton = true;
                                                      });
                                                      _resetUnlockButtonTimer();
                                                    },
                                                  ),
                                                  SizedBox(width: spacing),
                                                  GestureDetector(
                                                    behavior: HitTestBehavior.opaque,
                                                    onTap: () {
                                                      _resetHideTimer();
                                                      setState(() => _showVideoMorePanel = true);
                                                    },
                                                    child: Padding(
                                                      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
                                                      child: Icon(Icons.more_vert, color: Colors.white, size: iconSize + 2),
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ],
                                          ),
                                        ),
                                        GestureDetector(
                                          onTap: () {
                                            _resetHideTimer();
                                            _showSpeedSheet(context);
                                          },
                                          child: _buildCapsuleGlassContainer(
                                            padding: isLandscape
                                                ? const EdgeInsets.symmetric(horizontal: 14)
                                                : const EdgeInsets.symmetric(horizontal: 10),
                                            height: capsuleHeight,
                                            useOwnLayer: true,
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(Icons.speed_rounded, color: Colors.white, size: iconSize - 1),
                                                const SizedBox(width: 4),
                                                Text(
                                                  '${_speed.toStringAsFixed(_speed == _speed.roundToDouble() ? 0 : 2)}x',
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontSize: isLandscape ? 13 : 12,
                                                    fontWeight: FontWeight.w700,
                                                    letterSpacing: 0.3,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),

                            const SizedBox(height: 8),

                            // Main Seeker Capsule
                            if (_isTrimmingMode)
                              _buildCapsuleGlassContainer(
                                height: null,
                                defaultRadius: 20,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _buildTrimmingSlider(value.duration),
                                    const SizedBox(height: 8),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        TextButton(
                                          onPressed: () => setState(() => _isTrimmingMode = false),
                                          child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
                                        ),
                                        const SizedBox(width: 12),
                                        _isSavingTrim
                                            ? SizedBox(
                                                width: 20,
                                                height: 20,
                                                child: CircularProgressIndicator(color: mediaGold, strokeWidth: 2),
                                              )
                                            : TextButton(
                                                onPressed: _canSaveTrim ? _performTrim : null,
                                                child: Text(
                                                  'Save Trim',
                                                  style: TextStyle(
                                                    color: mediaGold,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                      ],
                                    ),
                                  ],
                                ),
                              )
                            else
                              _buildCapsuleGlassContainer(
                                height: 54,
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                child: ValueListenableBuilder<VideoPlayerValue>(
                                  valueListenable: video,
                                  builder: (context, val, child) {
                                    final position = val.position;
                                    final totalDuration = val.duration;
                                    final totalMs = totalDuration.inMilliseconds;
                                    final currentMs = totalMs <= 0
                                        ? 0.0
                                        : position.inMilliseconds.clamp(0, totalMs).toDouble();
                                    final remaining = totalDuration - position;

                                    return Row(
                                      children: [
                                        Text(
                                          formatMediaDuration(position),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        Expanded(
                                          child: MediaSlider(
                                            position: Duration(milliseconds: currentMs.round()),
                                            duration: Duration(milliseconds: totalMs.round()),
                                            showTimeLabels: false,
                                            activeColor: Colors.white,
                                            inactiveColor: Colors.white24,
                                            thumbColor: Colors.white,
                                            onChanged: (val) {
                                              _resetHideTimer();
                                              video.seekTo(val);
                                            },
                                          ),
                                        ),
                                        Text(
                                          totalMs <= 0 ? '--:--' : '-${formatMediaDuration(remaining)}',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _buildSpeedOverlay(),
            _buildVideoMoreOverlay(),
            _buildGifOverlay(),
            if (_isScreenLocked && _showUnlockButton) _buildScreenLockUnlockOverlay(),
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

    final screenWidth = MediaQuery.sizeOf(context).width;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final colors = DuckColors.of(context);

    // Responsive scaling
    final scale = (screenHeight / 820).clamp(0.5, 1.0);
    final artworkSize = (screenWidth * 0.72).clamp(180.0, 300.0);

    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final currentItem = widget.controller.playerItem ?? widget.item;
        if (_lastAudioItemId != null && _lastAudioItemId != currentItem.id) {
          _cachedAudioDuration = Duration.zero;
          _draggedAudioPosition = null;
        }
        _lastAudioItemId = currentItem.id;

        return SizedBox.expand(
          child: Stack(
            children: [
              // Blurred ambient backdrop
              Positioned.fill(
                child: MediaThumb(
                  url: currentItem.thumbnail,
                  filePath: currentItem.filePath,
                  preferNetworkThumbnail: true,
                  width: double.infinity,
                  height: double.infinity,
                  icon: Icons.music_note,
                ),
              ),
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 55, sigmaY: 55),
                  child: Container(
                    color: Colors.black.withOpacity(0.6),
                  ),
                ),
              ),

              // Foreground UI
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Top Header Row
                      DuckLiquidGlassLayer(
                        settings: DuckLiquidGlass.button(),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            _buildCircularGlassButton(
                              child: const Icon(Icons.close, color: Colors.white, size: 22),
                              onPressed: widget.controller.closePlayer,
                              useOwnLayer: false,
                            ),
                            const Text(
                              'Now Playing',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5,
                              ),
                            ),
                            _buildCircularGlassButton(
                              child: AnimatedFavoriteButton(
                                isFavorite: currentItem.favorite,
                                size: 20,
                                onTap: () {
                                  widget.controller.toggleFavorite(currentItem);
                                },
                              ),
                              onPressed: null,
                              useOwnLayer: false,
                            ),
                          ],
                        ),
                      ),

                      // Scaling artwork card
                      Expanded(
                        child: Center(
                          child: ScaleTransition(
                            scale: Tween<double>(begin: 0.88, end: 1.0).animate(
                              CurvedAnimation(
                                parent: _discRotationController,
                                curve: Curves.easeOutBack,
                              ),
                            ),
                            child: Container(
                              width: artworkSize,
                              height: artworkSize,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(28),
                                border: Border.all(
                                  color: colors.glassBorder,
                                  width: 1.5,
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Colors.black45,
                                    blurRadius: 28,
                                    offset: Offset(0, 12),
                                  ),
                                ],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(26),
                                child: MediaThumb(
                                  url: currentItem.thumbnail,
                                  filePath: currentItem.filePath,
                                  preferNetworkThumbnail: true,
                                  width: artworkSize,
                                  height: artworkSize,
                                  icon: Icons.music_note,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),

                      // Metadata section
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              currentItem.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 22 * scale,
                                fontWeight: FontWeight.bold,
                                letterSpacing: -0.5,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              currentItem.artist ?? currentItem.platform,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: mediaWarmGold,
                                fontSize: 16 * scale,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),

                  // Seeker Slider Capsule
                  if (_isTrimmingMode)
                    _buildCapsuleGlassContainer(
                      height: null,
                      defaultRadius: 20,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildTrimmingSlider(duration),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                onPressed: () => setState(() => _isTrimmingMode = false),
                                child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
                              ),
                              const SizedBox(width: 12),
                              _isSavingTrim
                                  ? SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(color: mediaGold, strokeWidth: 2),
                                    )
                                  : TextButton(
                                      onPressed: _canSaveTrim ? _performTrim : null,
                                      child: Text(
                                        'Save Trim',
                                        style: TextStyle(
                                          color: mediaGold,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                            ],
                          ),
                        ],
                      ),
                    )
                  else
                    _buildCapsuleGlassContainer(
                      height: 54,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: StreamBuilder<Duration>(
                        stream: audio.positionStream,
                        builder: (context, positionSnapshot) {
                          return StreamBuilder<Duration?>(
                            stream: audio.durationStream,
                            builder: (context, durationSnapshot) {
                              var position = positionSnapshot.data ?? audio.position;
                              if (_draggedAudioPosition != null) {
                                position = _draggedAudioPosition!;
                              }

                              var totalDuration = durationSnapshot.data ?? audio.duration ?? Duration.zero;
                              if (totalDuration > Duration.zero) {
                                _cachedAudioDuration = totalDuration;
                              } else if (_cachedAudioDuration > Duration.zero) {
                                totalDuration = _cachedAudioDuration;
                              }

                              final totalMs = totalDuration.inMilliseconds;
                              final currentMs = totalMs <= 0
                                  ? 0.0
                                  : position.inMilliseconds.clamp(0, totalMs).toDouble();
                              final remaining = totalDuration - position;

                              return Row(
                                children: [
                                  Text(
                                    formatMediaDuration(position),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                   Expanded(
                                     child: MediaSlider(
                                       position: Duration(milliseconds: currentMs.round()),
                                       duration: Duration(milliseconds: totalMs.round()),
                                       showTimeLabels: false,
                                       activeColor: Colors.white,
                                       inactiveColor: Colors.white24,
                                       thumbColor: Colors.white,
                                       onChanged: (val) {
                                         _resetHideTimer();
                                         if (mounted) setState(() => _draggedAudioPosition = val);
                                       },
                                       onChangeEnd: (val) {
                                         if (mounted) setState(() => _draggedAudioPosition = null);
                                         audio.seek(val);
                                       },
                                     ),
                                   ),
                                  Text(
                                    totalMs <= 0 ? '--:--' : '-${formatMediaDuration(remaining)}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              );
                            },
                          );
                        },
                      ),
                    ),

                  const SizedBox(height: 16),

                  // Main Audio Playback Controls
                  if (!_isTrimmingMode)
                    DuckLiquidGlassLayer(
                      settings: DuckLiquidGlass.button(),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            icon: Icon(
                              widget.controller.hasPreviousTrack
                                  ? Icons.skip_previous
                                  : Icons.skip_previous_outlined,
                              size: 32,
                              color: widget.controller.hasPreviousTrack
                                  ? Colors.white
                                  : Colors.white24,
                            ),
                            onPressed: widget.controller.hasPreviousTrack
                                ? widget.controller.playPrevious
                                : null,
                          ),
                          _buildCircularGlassButton(
                            size: 48,
                            child: const Icon(Icons.replay_10, color: Colors.white, size: 22),
                            onPressed: () {
                              _resetHideTimer();
                              _seekAudio(const Duration(seconds: -10));
                            },
                            useOwnLayer: false,
                          ),
                          _buildCircularGlassButton(
                            size: 78,
                            child: Icon(
                              isCompleted
                                  ? Icons.replay
                                  : playing
                                  ? Icons.pause
                                  : Icons.play_arrow,
                              color: Colors.white,
                              size: 38,
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
                            useOwnLayer: false,
                          ),
                          _buildCircularGlassButton(
                            size: 48,
                            child: const Icon(Icons.forward_10, color: Colors.white, size: 22),
                            onPressed: () {
                              _resetHideTimer();
                              _seekAudio(const Duration(seconds: 10));
                            },
                            useOwnLayer: false,
                          ),
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            icon: Icon(
                              widget.controller.hasNextTrack
                                  ? Icons.skip_next
                                  : Icons.skip_next_outlined,
                              size: 32,
                              color: widget.controller.hasNextTrack
                                  ? Colors.white
                                  : Colors.white24,
                            ),
                            onPressed: widget.controller.hasNextTrack
                                ? widget.controller.playNext
                                : null,
                          ),
                        ],
                      ),
                    ),

                  const SizedBox(height: 16),

                  // Volume Slider Flanked by Speakers
                  if (!_isTrimmingMode)
                    StreamBuilder<double>(
                      stream: audio.volumeStream,
                      builder: (context, snapshot) {
                        final vol = snapshot.data ?? audio.volume;
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          child: Row(
                            children: [
                              const Icon(Icons.volume_down_outlined, color: Colors.white30, size: 16),
                              Expanded(
                                child: MediaSlider(
                                  position: Duration(milliseconds: (vol * 1000).round()),
                                  duration: const Duration(milliseconds: 1000),
                                  showTimeLabels: false,
                                  activeColor: Colors.white,
                                  inactiveColor: Colors.white24,
                                  thumbColor: Colors.white,
                                  onChanged: (val) {
                                    _resetHideTimer();
                                    audio.setVolume(val.inMilliseconds / 1000.0);
                                  },
                                ),
                              ),
                              const Icon(Icons.volume_up_outlined, color: Colors.white30, size: 16),
                            ],
                          ),
                        );
                      },
                    ),

                  const SizedBox(height: 12),

                  // Bottom Auxiliary Options Capsule
                  if (!_isTrimmingMode)
                    _buildCapsuleGlassContainer(
                      height: 52,
                      padding: EdgeInsets.zero,
                      useOwnLayer: false,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            physics: const BouncingScrollPhysics(),
                            child: Container(
                              constraints: BoxConstraints(minWidth: constraints.maxWidth),
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  IconButton(
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    icon: Icon(
                                      widget.controller.shuffleEnabled
                                          ? Icons.shuffle
                                          : Icons.shuffle_outlined,
                                      size: 20,
                                      color: widget.controller.shuffleEnabled
                                          ? mediaGold
                                          : Colors.white60,
                                    ),
                                    onPressed: widget.controller.toggleShuffle,
                                  ),
                                  const SizedBox(width: 8),
                                  GestureDetector(
                                    onTap: () {
                                      _resetHideTimer();
                                      _showSpeedSheet(context);
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                      decoration: BoxDecoration(
                                        color: mediaGold.withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(20),
                                        border: Border.all(
                                          color: mediaGold.withValues(alpha: 0.45),
                                          width: 1,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.speed_rounded, size: 15, color: mediaGold),
                                          const SizedBox(width: 4),
                                          Text(
                                            '${_speed.toStringAsFixed(_speed == _speed.roundToDouble() ? 0 : 2)}x',
                                            style: TextStyle(
                                              color: mediaGold,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w800,
                                              letterSpacing: 0.3,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  if (!kIsWeb) ...[
                                    IconButton(
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      icon: const Icon(Icons.content_cut, color: Colors.white70, size: 18),
                                      onPressed: duration <= Duration.zero
                                          ? null
                                          : () {
                                              setState(() {
                                                _isTrimmingMode = true;
                                                _trimStart = 0.0;
                                                _trimEnd = duration.inSeconds.toDouble();
                                              });
                                            },
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  IconButton(
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    icon: const Icon(Icons.delete_outline, color: mediaDanger, size: 18),
                                    onPressed: () {
                                      widget.controller.closePlayer();
                                      widget.controller.deleteDownload(widget.item);
                                    },
                                  ),
                                  const SizedBox(width: 8),
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () {
                                      _resetHideTimer();
                                      setState(() => _showSleepTimerPanel = true);
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.all(4.0),
                                      child: ListenableBuilder(
                                        listenable: widget.controller,
                                        builder: (context, _) {
                                          final active = widget.controller.isSleepTimerActive;
                                          return Stack(
                                            clipBehavior: Clip.none,
                                            children: [
                                              Icon(
                                                active ? Icons.mode_night : Icons.mode_night_outlined,
                                                color: active ? mediaGold : Colors.white60,
                                                size: 20,
                                              ),
                                              if (active)
                                                Positioned(
                                                  right: -2,
                                                  top: -2,
                                                  child: Container(
                                                    width: 6,
                                                    height: 6,
                                                    decoration: const BoxDecoration(
                                                      color: mediaDanger,
                                                      shape: BoxShape.circle,
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    icon: Icon(
                                      switch (widget.controller.loopMode) {
                                        LoopMode.one => Icons.repeat_one,
                                        LoopMode.all => Icons.repeat,
                                        LoopMode.off => Icons.repeat_outlined,
                                      },
                                      size: 20,
                                      color: widget.controller.loopMode == LoopMode.off
                                          ? Colors.white60
                                          : mediaGold,
                                    ),
                                    onPressed: widget.controller.toggleLoopMode,
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    icon: const Icon(
                                      Icons.queue_music,
                                      size: 20,
                                      color: Colors.white60,
                                    ),
                                    onPressed: () {
                                      _resetHideTimer();
                                      setState(() => _showQueuePanel = true);
                                    },
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
          _buildSpeedOverlay(),
          _buildSleepTimerOverlay(),
          _buildQueueOverlay(),
          _buildGifOverlay(),
        ],
      ),
    );
  },
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

  // ─── Speed sheet ──────────────────────────────────────────────────────────
  void _showSpeedSheet(BuildContext context) {
    setState(() {
      _showSpeedPanel = true;
    });
  }

  Widget _buildSpeedOverlay() {
    if (!_showSpeedPanel) return const SizedBox.shrink();

    const speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    final isLight = Theme.of(context).brightness == Brightness.light;

    return Positioned.fill(
      child: Stack(
        children: [
          // Dismiss tap target backdrop
          Positioned.fill(
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _showSpeedPanel = false;
                });
              },
              behavior: HitTestBehavior.opaque,
              child: Container(
                color: Colors.black.withOpacity(0.4),
              ),
            ),
          ),
          // Speed panel content aligned to bottom
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _DismissiblePanel(
              onDismiss: () => setState(() => _showSpeedPanel = false),
              child: ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              child: DuckLiquidGlassSurface(
                borderRadius: 28,
                variant: DuckLiquidGlassVariant.panel,
                isLight: isLight,
                child: Container(
                  padding: EdgeInsets.fromLTRB(
                    24,
                    20,
                    24,
                    28 + MediaQuery.paddingOf(context).bottom,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Drag handle indicator
                      Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 20),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      // Title row
                      Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: mediaGold.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(Icons.speed_rounded, color: mediaGold, size: 20),
                          ),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Playback Speed',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.2,
                                ),
                              ),
                              Text(
                                'Current: ${_speed.toStringAsFixed(_speed == _speed.roundToDouble() ? 0 : 2)}x',
                                style: TextStyle(
                                  color: mediaGold,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      // Speed options grid
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          childAspectRatio: 2.2,
                        ),
                        itemCount: speeds.length,
                        itemBuilder: (_, i) {
                          final spd = speeds[i];
                          final isSelected = _speed == spd;
                          return GestureDetector(
                            onTap: () {
                              _setSpeed(spd);
                              setState(() {
                                _showSpeedPanel = false;
                              });
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeOutCubic,
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? mediaGold.withOpacity(0.18)
                                    : Colors.white.withOpacity(0.05),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isSelected
                                      ? mediaGold.withOpacity(0.7)
                                      : Colors.white.withOpacity(0.1),
                                  width: isSelected ? 1.5 : 1,
                                ),
                              ),
                              child: Center(
                                child: Text(
                                  '${spd.toStringAsFixed(spd == spd.roundToDouble() ? 0 : 2)}x',
                                  style: TextStyle(
                                    color: isSelected ? mediaGold : Colors.white70,
                                    fontSize: 13,
                                    fontWeight: isSelected
                                        ? FontWeight.w800
                                        : FontWeight.w500,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                      // Normal speed shortcut button
                      if (_speed != 1.0)
                        TextButton(
                          onPressed: () {
                            _setSpeed(1.0);
                            setState(() {
                              _showSpeedPanel = false;
                            });
                          },
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white60,
                            textStyle: const TextStyle(fontSize: 13),
                          ),
                          child: const Text('Reset to Normal (1x)'),
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
    );
  }

  Widget _buildSleepTimerOverlay() {
    if (!_showSleepTimerPanel) return const SizedBox.shrink();
    final isLight = Theme.of(context).brightness == Brightness.light;

    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _showSleepTimerPanel = false;
                });
              },
              behavior: HitTestBehavior.opaque,
              child: Container(
                color: Colors.black.withOpacity(0.5),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              child: DuckLiquidGlassSurface(
                borderRadius: 28,
                variant: DuckLiquidGlassVariant.panel,
                isLight: isLight,
                child: Container(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    16,
                    20,
                    20 + MediaQuery.paddingOf(context).bottom,
                  ),
                  child: ListenableBuilder(
                    listenable: widget.controller,
                    builder: (context, _) {
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(
                              color: Colors.white24,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Sleep Timer',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 16),
                          _buildSleepTimerPanelOption('15 minutes', const Duration(minutes: 15)),
                          _buildSleepTimerPanelOption('30 minutes', const Duration(minutes: 30)),
                          _buildSleepTimerPanelOption('45 minutes', const Duration(minutes: 45)),
                          _buildSleepTimerPanelOption('60 minutes', const Duration(minutes: 60)),
                          ListTile(
                            title: const Text('End of current track', style: TextStyle(color: Colors.white70)),
                            trailing: widget.controller.sleepTimerLabel == 'End of track'
                                ? Icon(Icons.check, color: mediaGold)
                                : null,
                            onTap: () {
                              widget.controller.setSleepTimerEndOfTrack();
                              setState(() {
                                _showSleepTimerPanel = false;
                              });
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Sleep timer set: End of current track'),
                                  duration: Duration(seconds: 2),
                                ),
                              );
                            },
                          ),
                          if (widget.controller.isSleepTimerActive) ...[
                            const Divider(color: Colors.white24),
                            ListTile(
                              title: Text('Cancel timer', style: TextStyle(color: mediaDanger)),
                              onTap: () {
                                widget.controller.cancelSleepTimer();
                                setState(() {
                                  _showSleepTimerPanel = false;
                                });
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Sleep timer cancelled'),
                                    duration: Duration(seconds: 2),
                                  ),
                                );
                              },
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSleepTimerPanelOption(String label, Duration duration) {
    return ListTile(
      title: Text(label, style: const TextStyle(color: Colors.white70)),
      trailing: widget.controller.sleepTimerLabel == label
          ? Icon(Icons.check, color: mediaGold)
          : null,
      onTap: () {
        widget.controller.setSleepTimer(duration, label);
        setState(() {
          _showSleepTimerPanel = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sleep timer set: $label'),
            duration: const Duration(seconds: 2),
          ),
        );
      },
    );
  }

  /// Back, inside the player, closes the innermost thing first.
  ///
  /// Registered with the controller rather than wired to a PopScope of its
  /// own: two PopScopes on one route both fire, so the panel would close and
  /// the root handler would tear down the player in the same gesture.
  ///
  /// Returns true when it consumed the gesture.
  bool _handleBack() {
    if (_showVideoMorePanel || _showSpeedPanel || _showQueuePanel) {
      setState(() {
        _showVideoMorePanel = false;
        _showSpeedPanel = false;
        _showQueuePanel = false;
      });
      return true;
    }

    // Landscape is a mode the user entered deliberately, so back should leave
    // it before it leaves the video — closing straight to a portrait library
    // from fullscreen is the single most jarring thing back can do here.
    if (mounted &&
        MediaQuery.orientationOf(context) == Orientation.landscape) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      return true;
    }

    if (_isScreenLocked) {
      // The lock exists to stop stray touches. Letting back out of the player
      // through it would defeat the point, so surface the unlock affordance
      // instead and swallow the gesture.
      setState(() => _showUnlockButton = true);
      return true;
    }

    return false;
  }

  Widget _buildVideoMoreOverlay() {
    if (!_showVideoMorePanel) return const SizedBox.shrink();
    final isLight = Theme.of(context).brightness == Brightness.light;

    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _showVideoMorePanel = false;
                });
              },
              behavior: HitTestBehavior.opaque,
              child: Container(
                color: Colors.black.withOpacity(0.5),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _DismissiblePanel(
              onDismiss: () => setState(() => _showVideoMorePanel = false),
              child: ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              child: DuckLiquidGlassSurface(
                borderRadius: 28,
                variant: DuckLiquidGlassVariant.panel,
                isLight: isLight,
                child: Container(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    16,
                    20,
                    20 + MediaQuery.paddingOf(context).bottom,
                  ),
                  child: ListenableBuilder(
                    listenable: widget.controller,
                    builder: (context, _) {
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 36,
                            height: 4,
                            decoration: BoxDecoration(
                              color: Colors.white24,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'More Options',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 16),
                          ListTile(
                            leading: const Icon(Icons.headphones, color: Colors.white70),
                            title: const Text(
                              'Background Audio Playback',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: const Text(
                              'Listen to video audio with screen off',
                              style: TextStyle(color: Colors.white38, fontSize: 12),
                            ),
                            onTap: () async {
                              setState(() {
                                _showVideoMorePanel = false;
                              });
                              final video = _video;
                              if (video == null || !video.value.isInitialized) return;
                              final pos = video.value.position;
                              _hideTimer?.cancel();
                              video.pause();
                              await widget.controller.activateBackgroundAudio(pos);
                              widget.controller.closePlayer();
                            },
                          ),
                          const Divider(color: Colors.white12),
                          ListTile(
                            leading: Icon(
                              _isLooping ? Icons.repeat_one : Icons.repeat,
                              color: _isLooping ? mediaGold : Colors.white70,
                            ),
                            title: Text(
                              _isLooping ? 'Loop Video (Active)' : 'Loop Video',
                              style: TextStyle(
                                color: _isLooping ? mediaGold : Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            trailing: Switch(
                              value: _isLooping,
                              activeColor: mediaGold,
                              onChanged: (val) {
                                setState(() {
                                  _isLooping = val;
                                  _video?.setLooping(_isLooping);
                                  _showVideoMorePanel = false;
                                });
                              },
                            ),
                            onTap: () {
                              setState(() {
                                _isLooping = !_isLooping;
                                _video?.setLooping(_isLooping);
                                _showVideoMorePanel = false;
                              });
                            },
                          ),
                          const Divider(color: Colors.white12),
                          ListTile(
                            leading: const Icon(Icons.delete_outline, color: mediaDanger),
                            title: const Text(
                              'Delete Video',
                              style: TextStyle(
                                color: mediaDanger,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            onTap: () {
                              setState(() {
                                _showVideoMorePanel = false;
                              });
                              widget.controller.closePlayer();
                              widget.controller.deleteDownload(widget.item);
                            },
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQueueOverlay() {
    if (!_showQueuePanel) return const SizedBox.shrink();
    final isLight = Theme.of(context).brightness == Brightness.light;

    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _showQueuePanel = false;
                });
              },
              behavior: HitTestBehavior.opaque,
              child: Container(
                color: Colors.black.withOpacity(0.5),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            top: MediaQuery.sizeOf(context).height * 0.35,
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              child: DuckLiquidGlassSurface(
                borderRadius: 28,
                variant: DuckLiquidGlassVariant.panel,
                isLight: isLight,
                child: AudioQueueSheet(controller: widget.controller),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showGifMakerSheet(BuildContext context) {
    if (_video == null) return;
    _resetHideTimer();
    _video?.pause();

    final double maxSec = _video!.value.duration.inSeconds.toDouble();
    double currentSec = _video!.value.position.inSeconds.toDouble();
    if (currentSec > maxSec - 1) {
      currentSec = (maxSec - 5).clamp(0.0, maxSec);
    }
    
    setState(() {
      _gifStartTime = currentSec;
      _gifDuration = 5.0;
      _gifWidth = 320;
      _showGifPanel = true;
    });
  }

  Widget _buildGifOverlay() {
    if (!_showGifPanel || _video == null) return const SizedBox.shrink();

    final isLight = Theme.of(context).brightness == Brightness.light;
    final maxSec = _video!.value.duration.inSeconds.toDouble();

    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () {
                setState(() {
                  _showGifPanel = false;
                });
              },
              behavior: HitTestBehavior.opaque,
              child: Container(
                color: Colors.black.withOpacity(0.4),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _DismissiblePanel(
              onDismiss: () => setState(() => _showQueuePanel = false),
              child: ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
              child: DuckLiquidGlassSurface(
                borderRadius: 28,
                variant: DuckLiquidGlassVariant.panel,
                isLight: isLight,
                child: Container(
                  padding: EdgeInsets.fromLTRB(
                    24,
                    20,
                    24,
                    28 + MediaQuery.paddingOf(context).bottom,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 20),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          Icon(Icons.gif, color: mediaGold, size: 28),
                          const SizedBox(width: 12),
                          const Text(
                            'Smart GIF Maker',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Start Time', style: TextStyle(color: Colors.white70)),
                          Text('${_gifStartTime.toStringAsFixed(1)}s / ${maxSec.toStringAsFixed(1)}s', style: TextStyle(color: mediaGold, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      Slider(
                        value: _gifStartTime,
                        min: 0.0,
                        max: maxSec,
                        activeColor: mediaGold,
                        inactiveColor: Colors.white10,
                        onChanged: _isSavingGif ? null : (val) {
                          setState(() {
                            _gifStartTime = val;
                          });
                        },
                      ),
                      
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Duration', style: TextStyle(color: Colors.white70)),
                          Text('${_gifDuration.toStringAsFixed(1)}s', style: TextStyle(color: mediaGold, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      Slider(
                        value: _gifDuration,
                        min: 1.0,
                        max: (maxSec - _gifStartTime).clamp(1.0, 15.0),
                        activeColor: mediaGold,
                        inactiveColor: Colors.white10,
                        onChanged: _isSavingGif ? null : (val) {
                          setState(() {
                            _gifDuration = val;
                          });
                        },
                      ),

                      const SizedBox(height: 12),
                      const Text('GIF Resolution (Width)', style: TextStyle(color: Colors.white70)),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(color: _gifWidth == 320 ? mediaGold : Colors.white24),
                                backgroundColor: _gifWidth == 320 ? mediaGold.withOpacity(0.1) : Colors.transparent,
                              ),
                              onPressed: _isSavingGif ? null : () => setState(() => _gifWidth = 320),
                              child: Text('320px (Compact)', style: TextStyle(color: _gifWidth == 320 ? mediaGold : Colors.white70)),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(color: _gifWidth == 480 ? mediaGold : Colors.white24),
                                backgroundColor: _gifWidth == 480 ? mediaGold.withOpacity(0.1) : Colors.transparent,
                              ),
                              onPressed: _isSavingGif ? null : () => setState(() => _gifWidth = 480),
                              child: Text('480px (HQ)', style: TextStyle(color: _gifWidth == 480 ? mediaGold : Colors.white70)),
                            ),
                          ),
                        ],
                      ),
                      
                      const SizedBox(height: 28),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: mediaGold,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: _isSavingGif
                            ? null
                            : () async {
                                setState(() {
                                  _isSavingGif = true;
                                });
                                try {
                                  await widget.controller.createGifFromVideo(
                                    widget.item,
                                    _gifStartTime,
                                    _gifDuration,
                                    _gifWidth,
                                  );
                                  setState(() {
                                    _showGifPanel = false;
                                  });
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('GIF created successfully! Check Images vault.'),
                                        backgroundColor: mediaGold,
                                      ),
                                    );
                                  }
                                } catch (e) {
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('Failed to create GIF: $e'),
                                        backgroundColor: Colors.redAccent,
                                      ),
                                    );
                                  }
                                } finally {
                                  if (mounted) {
                                    setState(() {
                                      _isSavingGif = false;
                                    });
                                  }
                                }
                              },
                        child: _isSavingGif
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2),
                              )
                            : const Text('Create GIF', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
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
    );
  }

  Widget _buildCircularGlassButton({
    required Widget child,
    required VoidCallback? onPressed,
    double size = 48,
    bool useOwnLayer = true,
  }) {
    final buttonContent = SizedBox(
      width: size,
      height: size,
      child: Center(child: child),
    );

    if (onPressed == null) {
      return DuckLiquidGlassSurface(
        borderRadius: size / 2,
        clipOval: true,
        variant: DuckLiquidGlassVariant.button,
        useOwnLayer: useOwnLayer,
        blurSigma: 20,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
        fallbackGradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.18),
            Colors.white.withValues(alpha: 0.04),
          ],
        ),
        fallbackBorderColor: Colors.white.withValues(alpha: 0.24),
        child: buttonContent,
      );
    }

    return LiquidGlassInteractiveButton(
      onTap: onPressed,
      size: size,
      useOwnLayer: useOwnLayer,
      child: buttonContent,
    );
  }

  Widget _buildCapsuleGlassContainer({
    required Widget child,
    double? width,
    double? height = 48,
    double defaultRadius = 24,
    EdgeInsetsGeometry? padding,
    bool useOwnLayer = true,
  }) {
    final radius = height != null ? height / 2 : defaultRadius;
    return DuckLiquidGlassSurface(
      borderRadius: radius,
      variant: DuckLiquidGlassVariant.capsule,
      useOwnLayer: useOwnLayer,
      blurSigma: 20,
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.25),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ],
      fallbackGradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: 0.18),
          Colors.white.withValues(alpha: 0.04),
        ],
      ),
      fallbackBorderColor: Colors.white.withValues(alpha: 0.24),
      child: SizedBox(
        width: width,
        height: height,
        child: Padding(
          padding: padding ?? EdgeInsets.zero,
          child: child,
        ),
      ),
    );
  }
  Widget _buildScreenLockUnlockOverlay() {
    return Positioned(
      top: 48,
      left: 0,
      right: 0,
      child: Center(
        child: SafeArea(
          child: GestureDetector(
            onTap: () {
              HapticFeedback.mediumImpact();
              setState(() {
                _isScreenLocked = false;
                _showControls = true;
                _showUnlockButton = false;
              });
            },
            child: DuckLiquidGlassSurface(
              borderRadius: 24,
              variant: DuckLiquidGlassVariant.panel,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: mediaGold.withValues(alpha: 0.5), width: 1.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock_open_rounded, color: mediaGold, size: 20),
                    const SizedBox(width: 10),
                    const Text(
                      'Screen Locked — Tap to Unlock',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.3,
                      ),
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


/// A bottom panel that dismisses the way the platform's own sheets do.
///
/// The player paints its panels inside its own Stack rather than pushing them
/// as routes, so they get none of showModalBottomSheet's behaviour for free.
/// What they had instead was a drag handle drawn on top of nothing — worse
/// than no handle, because it advertises a gesture that does not exist. This
/// makes the gesture real: drag down past a threshold, or flick, and the panel
/// goes; let go short of it and it springs back.
class _DismissiblePanel extends StatefulWidget {
  const _DismissiblePanel({required this.onDismiss, required this.child});

  final VoidCallback onDismiss;
  final Widget child;

  @override
  State<_DismissiblePanel> createState() => _DismissiblePanelState();
}

class _DismissiblePanelState extends State<_DismissiblePanel>
    with TickerProviderStateMixin {
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..forward();

  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );

  /// How far the finger has pulled the panel down, in logical pixels.
  double _drag = 0;

  /// Past this, letting go dismisses instead of springing back.
  static const _dismissAfter = 90.0;

  /// A flick this fast dismisses regardless of how far it travelled.
  static const _flingVelocity = 700.0;

  @override
  void dispose() {
    _entrance.dispose();
    _settle.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _settle.stop();
    // Upward drags do nothing: the panel already sits against the bottom edge,
    // and letting it travel further would open a gap underneath it.
    setState(() => _drag = math.max(0, _drag + details.delta.dy));
  }

  void _onDragEnd(DragEndDetails details) {
    if (_drag > _dismissAfter ||
        details.velocity.pixelsPerSecond.dy > _flingVelocity) {
      widget.onDismiss();
      return;
    }
    final springBack = Tween<double>(begin: _drag, end: 0).animate(
      CurvedAnimation(parent: _settle, curve: Curves.easeOut),
    );
    springBack.addListener(() {
      if (mounted) setState(() => _drag = springBack.value);
    });
    _settle.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: _onDragUpdate,
      onVerticalDragEnd: _onDragEnd,
      child: AnimatedBuilder(
        animation: _entrance,
        builder: (context, child) {
          final entered = Curves.easeOutCubic.transform(_entrance.value);
          return Transform.translate(
            offset: Offset(0, _drag),
            child: FractionalTranslation(
              translation: Offset(0, 1 - entered),
              child: child,
            ),
          );
        },
        child: widget.child,
      ),
    );
  }
}
