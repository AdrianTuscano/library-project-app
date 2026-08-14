import 'package:flutter/material.dart';

/// App-wide navigator key. Used by VolumeShutterService to pop routes without
/// needing a BuildContext.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
