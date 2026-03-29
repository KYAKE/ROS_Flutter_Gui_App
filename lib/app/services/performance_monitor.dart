import 'dart:async';
import 'package:flutter/scheduler.dart';
import 'package:flutter/foundation.dart';
import 'package:ros_flutter_gui_app/app/logging/app_logger.dart';

/// Collected performance snapshot.
class PerformanceSnapshot {
  final double fps;
  final int droppedFrames;
  final Duration connectionLatency;
  final Duration mapRenderTime;
  final DateTime timestamp;

  const PerformanceSnapshot({
    required this.fps,
    required this.droppedFrames,
    required this.connectionLatency,
    required this.mapRenderTime,
    required this.timestamp,
  });

  @override
  String toString() =>
      'Perf(fps=${fps.toStringAsFixed(1)}, dropped=$droppedFrames, '
      'latency=${connectionLatency.inMilliseconds}ms, '
      'mapRender=${mapRenderTime.inMilliseconds}ms)';
}

/// Monitors application performance metrics including FPS, connection latency,
/// and rendering performance.
class PerformanceMonitor {
  static final PerformanceMonitor _instance = PerformanceMonitor._internal();
  factory PerformanceMonitor() => _instance;
  PerformanceMonitor._internal();

  static const String _tag = 'PerfMonitor';

  Timer? _reportTimer;
  bool _tracking = false;

  // FPS tracking
  int _frameCount = 0;
  int _droppedFrameCount = 0;
  DateTime _lastFpsReset = DateTime.now();
  double _currentFps = 0;

  // Connection latency
  Duration _lastConnectionLatency = Duration.zero;
  final Stopwatch _latencyStopwatch = Stopwatch();

  // Map render timing
  Duration _lastMapRenderTime = Duration.zero;

  // History for trend analysis
  final List<PerformanceSnapshot> _history = [];
  static const int _maxHistory = 120; // 2 minutes at 1/sec

  // Public accessors
  double get currentFps => _currentFps;
  Duration get connectionLatency => _lastConnectionLatency;
  Duration get mapRenderTime => _lastMapRenderTime;
  List<PerformanceSnapshot> get history => List.unmodifiable(_history);

  ValueNotifier<PerformanceSnapshot?> latestSnapshot = ValueNotifier(null);

  /// Start performance monitoring.
  void start({Duration reportInterval = const Duration(seconds: 10)}) {
    if (_tracking) return;
    _tracking = true;
    _lastFpsReset = DateTime.now();
    _frameCount = 0;
    _droppedFrameCount = 0;

    // Register frame callback for FPS tracking
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);

    // Periodic reporting
    _reportTimer = Timer.periodic(reportInterval, (_) => _report());
    AppLogger.i('Performance monitoring started', tag: _tag);
  }

  /// Stop performance monitoring.
  void stop() {
    if (!_tracking) return;
    _tracking = false;
    _reportTimer?.cancel();
    _reportTimer = null;

    try {
      SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    } catch (_) {}

    AppLogger.i('Performance monitoring stopped', tag: _tag);
  }

  void _onFrameTimings(List<FrameTiming> timings) {
    _frameCount += timings.length;
    for (final timing in timings) {
      final buildDuration = timing.buildDuration;
      final rasterDuration = timing.rasterDuration;
      final totalFrame = buildDuration + rasterDuration;
      // Consider a frame "dropped" if it exceeds 16.67ms budget (60fps target)
      if (totalFrame.inMilliseconds > 16) {
        _droppedFrameCount++;
      }
    }
  }

  /// Record the start of a connection attempt (call [endLatencyMeasure] when connected).
  void startLatencyMeasure() {
    _latencyStopwatch.reset();
    _latencyStopwatch.start();
  }

  /// Record the end of a connection attempt.
  void endLatencyMeasure() {
    _latencyStopwatch.stop();
    _lastConnectionLatency = _latencyStopwatch.elapsed;
  }

  /// Record a map rendering duration.
  void recordMapRenderTime(Duration duration) {
    _lastMapRenderTime = duration;
  }

  /// Convenience: wrap a function and record its duration as map render time.
  T measureMapRender<T>(T Function() fn) {
    final sw = Stopwatch()..start();
    final result = fn();
    sw.stop();
    _lastMapRenderTime = sw.elapsed;
    return result;
  }

  void _report() {
    final now = DateTime.now();
    final elapsed = now.difference(_lastFpsReset);
    _currentFps =
        elapsed.inMilliseconds > 0 ? _frameCount / elapsed.inSeconds.clamp(1, 999) : 0;

    final snapshot = PerformanceSnapshot(
      fps: _currentFps,
      droppedFrames: _droppedFrameCount,
      connectionLatency: _lastConnectionLatency,
      mapRenderTime: _lastMapRenderTime,
      timestamp: now,
    );

    _history.add(snapshot);
    while (_history.length > _maxHistory) {
      _history.removeAt(0);
    }
    latestSnapshot.value = snapshot;

    AppLogger.d(snapshot.toString(), tag: _tag);

    // Reset counters
    _frameCount = 0;
    _droppedFrameCount = 0;
    _lastFpsReset = now;
  }

  /// Get average FPS over the history window.
  double get averageFps {
    if (_history.isEmpty) return 0;
    return _history.map((s) => s.fps).reduce((a, b) => a + b) / _history.length;
  }

  /// Get total dropped frames over the history window.
  int get totalDroppedFrames {
    if (_history.isEmpty) return 0;
    return _history.map((s) => s.droppedFrames).reduce((a, b) => a + b);
  }
}
