import 'package:flutter/material.dart';
import 'package:rive/rive.dart' as rive;

import '../models/download_models.dart';

/// Contract the `.riv` file must satisfy.
///
/// These names are what the animator types into the Rive editor. Keeping them
/// in one place means re-exporting the artwork never turns into a hunt through
/// the widget tree — and if a name is wrong, [DuckRivePlayer] falls back to the
/// PNG sprites instead of showing nothing.
class DuckRiveSpec {
  DuckRiveSpec._();

  /// Bundled artwork. Absent by default; the sprite fallback covers that.
  static const asset = 'assets/rive/duck.riv';

  /// Preferred artboard and state machine. If the exported file names them
  /// differently, the player quietly uses the file's own defaults.
  static const artboardName = 'Duck';
  static const stateMachineName = 'DuckMachine';

  /// Number property, `0..3`, selecting the pose. Values mirror [DuckFlow] so
  /// the animator can build one blended state machine rather than four clips:
  /// 0 = idle, 1 = working (extracting/downloading), 2 = success, 3 = error.
  static const stateProperty = 'state';

  /// Number property, `0..100`. The live download percentage.
  ///
  /// This is the reason Rive is worth the swap: the duck can lean into the
  /// progress instead of looping the same clip regardless of what is happening.
  static const progressProperty = 'progress';

  /// Trigger fired when the user taps the duck.
  static const tapTrigger = 'tap';

  /// Numeric [stateProperty] value for a given flow.
  static double stateValueFor(DuckFlow flow) {
    return switch (flow) {
      DuckFlow.idle || DuckFlow.ready => 0,
      DuckFlow.extracting || DuckFlow.downloading => 1,
      DuckFlow.success => 2,
      DuckFlow.error => 3,
    };
  }
}

/// Plays the Duck state machine, driving it from app state.
///
/// Renders nothing and reports through [onUnavailable] when the file is
/// missing or does not match [DuckRiveSpec], so the caller keeps showing the
/// existing sprite animation. Dropping a `.riv` into `assets/rive/` is
/// therefore the entire installation step — no code change.
///
/// Values are written through Rive data binding, with a fallback to the older
/// state-machine inputs so a file exported either way still animates.
class DuckRivePlayer extends StatefulWidget {
  const DuckRivePlayer({
    super.key,
    required this.flow,
    required this.size,
    required this.progress,
    this.tapSignal = 0,
    this.onUnavailable,
  });

  final DuckFlow flow;
  final double size;

  /// Download completion, 0-100. Forwarded to [DuckRiveSpec.progressProperty].
  final int progress;

  /// Incremented by the parent on every tap; each change fires the tap trigger.
  /// A counter rather than a callback keeps this widget declarative.
  final int tapSignal;

  /// Called once if the artwork cannot be used.
  final VoidCallback? onUnavailable;

  @override
  State<DuckRivePlayer> createState() => _DuckRivePlayerState();
}

class _DuckRivePlayerState extends State<DuckRivePlayer> {
  rive.File? _file;
  rive.RiveWidgetController? _controller;
  _DuckRiveBindings? _bindings;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final file = await rive.File.asset(
        DuckRiveSpec.asset,
        riveFactory: rive.Factory.rive,
      );
      if (file == null) {
        _markUnavailable('asset ${DuckRiveSpec.asset} not found');
        return;
      }
      if (!mounted) {
        file.dispose();
        return;
      }

      final controller = _buildController(file);
      _bindings = _DuckRiveBindings.resolve(controller);
      _file = file;
      _controller = controller;
      _pushState();
      setState(() {});
    } catch (error, stack) {
      debugPrint('DuckRivePlayer: falling back to sprites — $error\n$stack');
      _markUnavailable(error.toString());
    }
  }

  /// Falls back to the file's own defaults when the named artboard or state
  /// machine is absent, so a file exported with different names still runs.
  rive.RiveWidgetController _buildController(rive.File file) {
    try {
      return rive.RiveWidgetController(
        file,
        artboardSelector: const rive.ArtboardNamed(DuckRiveSpec.artboardName),
        stateMachineSelector:
            const rive.StateMachineNamed(DuckRiveSpec.stateMachineName),
      );
    } catch (_) {
      return rive.RiveWidgetController(file);
    }
  }

  void _markUnavailable(String reason) {
    if (_failed) return;
    _failed = true;
    debugPrint('DuckRivePlayer unavailable: $reason');
    if (!mounted) return;
    setState(() {});
    widget.onUnavailable?.call();
  }

  @override
  void didUpdateWidget(DuckRivePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.flow != widget.flow ||
        oldWidget.progress != widget.progress) {
      _pushState();
    }
    if (oldWidget.tapSignal != widget.tapSignal) {
      _bindings?.fireTap();
    }
  }

  void _pushState() {
    _bindings?.setState(DuckRiveSpec.stateValueFor(widget.flow));
    _bindings?.setProgress(widget.progress.clamp(0, 100).toDouble());
  }

  @override
  void dispose() {
    _bindings?.dispose();
    _controller?.dispose();
    _file?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (_failed || controller == null) {
      // Nothing to draw. While loading this reserves the duck's footprint so
      // the layout does not jump when the artboard appears.
      return SizedBox(width: widget.size, height: widget.size);
    }

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: rive.RiveWidget(controller: controller, fit: rive.Fit.contain),
    );
  }
}

/// Writes to whichever control surface the exported file actually exposes.
///
/// Rive deprecated state-machine inputs in favour of data binding, but plenty
/// of files are still exported with inputs. Resolving both means the animator
/// is not forced to rebuild the file a particular way.
class _DuckRiveBindings {
  _DuckRiveBindings._({
    this.stateNumber,
    this.progressNumber,
    this.tapTrigger,
    this.stateInput,
    this.progressInput,
    this.tapInput,
  });

  final rive.ViewModelInstanceNumber? stateNumber;
  final rive.ViewModelInstanceNumber? progressNumber;
  final rive.ViewModelInstanceTrigger? tapTrigger;

  // ignore: deprecated_member_use
  final rive.NumberInput? stateInput;
  // ignore: deprecated_member_use
  final rive.NumberInput? progressInput;
  // ignore: deprecated_member_use
  final rive.TriggerInput? tapInput;

  static _DuckRiveBindings resolve(rive.RiveWidgetController controller) {
    rive.ViewModelInstanceNumber? stateNumber;
    rive.ViewModelInstanceNumber? progressNumber;
    rive.ViewModelInstanceTrigger? tapTrigger;

    try {
      final viewModel = controller.dataBind(rive.DataBind.auto());
      stateNumber = viewModel.number(DuckRiveSpec.stateProperty);
      progressNumber = viewModel.number(DuckRiveSpec.progressProperty);
      tapTrigger = viewModel.trigger(DuckRiveSpec.tapTrigger);
    } catch (error) {
      debugPrint('DuckRivePlayer: no data binding on this file — $error');
    }

    final hasDataBinding = stateNumber != null || progressNumber != null;
    if (hasDataBinding) {
      return _DuckRiveBindings._(
        stateNumber: stateNumber,
        progressNumber: progressNumber,
        tapTrigger: tapTrigger,
      );
    }

    final machine = controller.stateMachine;
    return _DuckRiveBindings._(
      // ignore: deprecated_member_use
      stateInput: machine.number(DuckRiveSpec.stateProperty),
      // ignore: deprecated_member_use
      progressInput: machine.number(DuckRiveSpec.progressProperty),
      // ignore: deprecated_member_use
      tapInput: machine.trigger(DuckRiveSpec.tapTrigger),
    );
  }

  void setState(double value) {
    stateNumber?.value = value;
    stateInput?.value = value;
  }

  void setProgress(double value) {
    progressNumber?.value = value;
    progressInput?.value = value;
  }

  void fireTap() {
    tapTrigger?.trigger();
    tapInput?.fire();
  }

  void dispose() {
    stateNumber?.dispose();
    progressNumber?.dispose();
    tapTrigger?.dispose();
    stateInput?.dispose();
    progressInput?.dispose();
    tapInput?.dispose();
  }
}
