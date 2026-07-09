import '../models/download_models.dart';

enum DuckSpriteSet { classic, premium }

class DuckSpriteState {
  const DuckSpriteState({
    required this.frames,
    required this.fps,
    required this.loop,
  });

  final List<String> frames;
  final int fps;
  final bool loop;
}

class DuckAssets {
  DuckAssets._();

  static const DuckSpriteSet activeSet = DuckSpriteSet.classic;
  static const int frameCount = 12;

  static const _classicFrames = 'assets/images/ducks/frames/classic';
  static const _premiumFrames = 'assets/images/ducks/frames/premium';
  static const _classicDucks = 'assets/images/ducks';
  static const _premiumDucks = 'assets/images/ducks/premium';

  static const logoSplash = 'assets/images/branding/liquid_glass_layers/layer-duck.png';
  static const logoApp = 'assets/images/branding/logo_app.png';
  static const logoMark = 'assets/images/branding/logo_mark.png';

  static const quackTap = 'assets/sounds/quack_tap.mp3';
  static const quackSuccess = 'assets/sounds/quack_success.mp3';
  static const quackFail = 'assets/sounds/quack_fail.mp3';
  static const quackClipboard = 'assets/sounds/quack_clipboard.mp3';

  static final List<String> _classicIdleFrames =
      _buildFramePaths(_classicFrames, 'idle');
  static final List<String> _classicLoadingFrames =
      _buildFramePaths(_classicFrames, 'loading');
  static final List<String> _classicSuccessFrames =
      _buildFramePaths(_classicFrames, 'success');
  static final List<String> _classicErrorFrames =
      _buildFramePaths(_classicFrames, 'error');

  static final List<String> _premiumIdleFrames =
      _buildFramePaths(_premiumFrames, 'idle');
  static final List<String> _premiumLoadingFrames =
      _buildFramePaths(_premiumFrames, 'loading');
  static final List<String> _premiumSuccessFrames =
      _buildFramePaths(_premiumFrames, 'success');
  static final List<String> _premiumErrorFrames =
      _buildFramePaths(_premiumFrames, 'error');

  static final DuckSpriteState _classicIdleSprite = DuckSpriteState(
    frames: _classicIdleFrames,
    fps: 4,
    loop: true,
  );
  static final DuckSpriteState _classicLoadingSprite = DuckSpriteState(
    frames: _classicLoadingFrames,
    fps: 5,
    loop: true,
  );
  static final DuckSpriteState _classicSuccessSprite = DuckSpriteState(
    frames: _classicSuccessFrames,
    fps: 6,
    loop: false,
  );
  static final DuckSpriteState _classicErrorSprite = DuckSpriteState(
    frames: _classicErrorFrames,
    fps: 5,
    loop: true,
  );

  static final DuckSpriteState _premiumIdleSprite = DuckSpriteState(
    frames: _premiumIdleFrames,
    fps: 4,
    loop: true,
  );
  static final DuckSpriteState _premiumLoadingSprite = DuckSpriteState(
    frames: _premiumLoadingFrames,
    fps: 5,
    loop: true,
  );
  static final DuckSpriteState _premiumSuccessSprite = DuckSpriteState(
    frames: _premiumSuccessFrames,
    fps: 6,
    loop: false,
  );
  static final DuckSpriteState _premiumErrorSprite = DuckSpriteState(
    frames: _premiumErrorFrames,
    fps: 5,
    loop: true,
  );

  static DuckSpriteState spriteFor(DuckFlow flow) {
    return switch (flow) {
      DuckFlow.extracting || DuckFlow.downloading => duckLoadingSprite(),
      DuckFlow.success => duckSuccessSprite(),
      DuckFlow.error => duckErrorSprite(),
      DuckFlow.idle || DuckFlow.ready => duckIdleSprite(),
    };
  }

  static DuckSpriteState duckIdleSprite() =>
      activeSet == DuckSpriteSet.premium
          ? _premiumIdleSprite
          : _classicIdleSprite;

  static DuckSpriteState duckLoadingSprite() =>
      activeSet == DuckSpriteSet.premium
          ? _premiumLoadingSprite
          : _classicLoadingSprite;

  static DuckSpriteState duckSuccessSprite() =>
      activeSet == DuckSpriteSet.premium
          ? _premiumSuccessSprite
          : _classicSuccessSprite;

  static DuckSpriteState duckErrorSprite() =>
      activeSet == DuckSpriteSet.premium
          ? _premiumErrorSprite
          : _classicErrorSprite;

  static List<String> _buildFramePaths(String base, String state) {
    return List<String>.unmodifiable(
      List.generate(
        frameCount,
        (index) =>
            '$base/$state/${state}_${(index + 1).toString().padLeft(2, '0')}.png',
      ),
    );
  }

  static String duckIdle() => _duck('duck_idle.png');
  static String duckLoading() => _duck('duck_loading.png');
  static String duckSuccess() => _duck('duck_success.png');
  static String duckError() => _duck('duck_angry.png');

  static String _duck(String fileName) {
    final base =
        activeSet == DuckSpriteSet.premium ? _premiumDucks : _classicDucks;
    if (activeSet == DuckSpriteSet.premium && fileName == 'duck_angry.png') {
      return '$_premiumDucks/duck_error.png';
    }
    return '$base/$fileName';
  }
}
