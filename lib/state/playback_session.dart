import 'package:just_audio/just_audio.dart';

/// What the one audio player is currently being used for.
enum PlaybackIntent {
  /// A track the user chose, heard at the volume they chose.
  music,

  /// A video's audio, loaded silently and kept ready.
  ///
  /// The video plays its own sound; this copy exists so that locking the
  /// screen only has to unmute. Android will not let a backgrounded app start
  /// the foreground service `just_audio_background` needs, so the service has
  /// to be alive before the screen goes off — which is why the copy is loaded
  /// early and muted rather than started late.
  videoStandby,
}

/// Owns the single audio player, and hands it between features.
///
/// There can only be one. `just_audio_background` refuses a second instance
/// outright — "just_audio_background supports only a single player instance" —
/// so music and a video's standby audio are not two players that happen to be
/// similar, they are one object used for two jobs.
///
/// That is fine until a job leaves something behind. Watching a video sets the
/// volume to zero on purpose; closing it used to stop playback without undoing
/// that, so the next song played perfectly and silently. Volume was simply the
/// one that got noticed — loop mode, speed and the loaded source sit on the
/// same object and can each do the same thing.
///
/// So nothing sets those directly any more. A feature says what it wants the
/// player *for*, and this class puts every shared property into the state that
/// intent requires. Forgetting to clean up is no longer possible, because
/// cleaning up is not a step anybody performs.
class PlaybackSession {
  PlaybackSession({
    required AudioPlayer player,
    required double Function() preferredVolume,
  }) : _player = player,
       _preferredVolume = preferredVolume;

  final AudioPlayer _player;

  /// The level the user set. Read through a callback rather than copied, so a
  /// change to the slider is picked up by the next handover.
  final double Function() _preferredVolume;

  PlaybackIntent? _intent;

  /// What the player is being used for, or null when nobody holds it.
  PlaybackIntent? get intent => _intent;

  bool get isMusic => _intent == PlaybackIntent.music;
  bool get isVideoStandby => _intent == PlaybackIntent.videoStandby;

  /// True while the standby copy is the one actually being heard.
  bool get videoAudioIsAudible => isVideoStandby && _audible;
  bool _audible = false;

  /// Takes the player for [intent], leaving every shared property correct.
  Future<void> acquire(PlaybackIntent intent, {LoopMode loop = LoopMode.off}) async {
    _intent = intent;
    _audible = intent == PlaybackIntent.music;
    await _apply(audible: _audible, loop: loop);
  }

  /// Makes a standby copy audible, at the volume the user set for it.
  ///
  /// Not a hardcoded full volume: the level belongs to the user, and the video
  /// borrowing the player is not a reason to overrule it.
  Future<void> unmute() async {
    _audible = true;
    await _player.setVolume(_preferredVolume());
  }

  Future<void> mute() async {
    _audible = false;
    await _player.setVolume(0);
  }

  /// Applies a volume the user just chose, if they are the one listening.
  ///
  /// While a video is providing the sound the player stays silent whatever the
  /// slider says — otherwise moving it would play the same audio twice, half a
  /// second apart.
  Future<void> applyPreferredVolume() async {
    if (!_audible) return;
    await _player.setVolume(_preferredVolume());
  }

  Future<void> setLoop(LoopMode loop) => _player.setLoopMode(loop);

  /// Gives the player back, at rest and audible.
  Future<void> release() async {
    _intent = null;
    _audible = false;
    await _player.stop();
    // Audible on the way out, whoever was holding it and however they left it.
    // Nobody is listening yet, so this is not about the current holder — it is
    // about the next one finding a player it can be heard through.
    //
    // Deliberately after the stop, because stopping does not touch volume: it
    // is a setting, not playback, which is exactly how a muted player survived
    // being stopped and swallowed the next song.
    await _apply(audible: true, loop: LoopMode.off);
  }

  Future<void> _apply({required bool audible, required LoopMode loop}) async {
    await _player.setVolume(audible ? _preferredVolume() : 0);
    await _player.setSpeed(1);
    await _player.setLoopMode(loop);
  }
}
