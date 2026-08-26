import 'package:flutter/cupertino.dart';

import '../widgets/duck_motion.dart';

/// One push transition for the whole app.
///
/// Inner pages were split between two motion languages: Settings arrived on a
/// MaterialPageRoute, so it rose from the bottom with the platform's own
/// animation, while the vault, playlists and the intruder log arrived on
/// CupertinoPageRoute and slid in from the right. Switching a tab slid
/// sideways as well, which left the bottom-rising page looking like it
/// belonged to a different app.
///
/// Built on CupertinoPageRoute rather than a hand-rolled PageRouteBuilder
/// because that class already carries the parts worth keeping: the parallax on
/// the page underneath, and the edge-swipe back gesture. Reimplementing the
/// gesture to gain nothing would have been the wrong trade.
///
/// The only change is pace. Cupertino's own 500ms is tuned for a phone you
/// navigate a handful of times per session; this is a library you move around
/// in constantly, and at that frequency 500ms is something you wait out.
class DuckPageRoute<T> extends CupertinoPageRoute<T> {
  DuckPageRoute({required super.builder, super.settings});

  @override
  Duration get transitionDuration => DuckMotion.transitionDuration;
}
