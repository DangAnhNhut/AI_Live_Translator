import 'dart:async';

import 'package:flutter/foundation.dart';

abstract interface class SessionClock {
  Duration get now;
}

abstract interface class SessionTicker {
  void start(VoidCallback onTick);

  void stop();

  void dispose();
}

class StopwatchSessionClock implements SessionClock {
  StopwatchSessionClock() : _stopwatch = Stopwatch()..start();

  final Stopwatch _stopwatch;

  @override
  Duration get now => _stopwatch.elapsed;
}

class PeriodicSessionTicker implements SessionTicker {
  Timer? _timer;

  @override
  void start(VoidCallback onTick) {
    stop();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => onTick());
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    stop();
  }
}
