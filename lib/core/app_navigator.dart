import 'package:flutter/material.dart';

/// A global navigator key so that widgets rendered outside the main Navigator
/// subtree (e.g. the player Overlay) can still push routes / show sheets.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
