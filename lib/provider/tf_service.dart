import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:ros_flutter_gui_app/app/logging/app_logger.dart';
import 'package:ros_flutter_gui_app/basic/RobotPose.dart';
import 'package:ros_flutter_gui_app/basic/occupancy_map.dart';
import 'package:ros_flutter_gui_app/basic/tf.dart';
import 'package:ros_flutter_gui_app/basic/tf2_dart.dart';
import 'package:ros_flutter_gui_app/global/setting.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

/// Manages TF (transform) data and provides event-driven robot pose updates
/// instead of fixed-interval polling.
class TfService {
  static const String _tag = 'TfService';

  final TF2Dart _tf = TF2Dart();

  final ValueNotifier<RobotPose> robotPoseMap = ValueNotifier(RobotPose.zero());
  final ValueNotifier<RobotPose> robotPoseScene =
      ValueNotifier(RobotPose.zero());

  /// The current map data, needed for coordinate conversion (xy2idx).
  ValueNotifier<OccupancyMap>? _mapNotifier;

  // Throttle pose updates to avoid excessive UI redraws
  DateTime _lastPoseUpdate = DateTime.now();
  static const Duration _poseUpdateInterval = Duration(milliseconds: 50);

  // Position smoothing to prevent teleporting artifacts
  RobotPose? _lastValidPose;
  // Max distance (meters) allowed per update; jumps beyond this are rejected
  static const double _maxJumpDistance = 0.5;
  // EMA smoothing factor (0~1, smaller = smoother)
  static const double _smoothingAlpha = 0.4;
  // Number of consecutive rejected poses before accepting a large jump
  int _rejectedCount = 0;
  static const int _maxRejectedCount = 10;

  TF2Dart get tf => _tf;

  /// Reset smoothing state (call on disconnect/reconnect).
  void resetSmoothing() {
    _lastValidPose = null;
    _rejectedCount = 0;
  }

  /// Bind to the occupancy map so pose scene coordinates can be computed.
  void bindMap(ValueNotifier<OccupancyMap> mapNotifier) {
    _mapNotifier = mapNotifier;
  }

  /// Process a TF message and update robot pose if applicable.
  Future<void> handleTfMessage(Map<String, dynamic> msg) async {
    _tf.updateTF(TF.fromJson(msg));
    _tryUpdateRobotPose();
  }

  /// Process a static TF message.
  Future<void> handleTfStaticMessage(Map<String, dynamic> msg) async {
    _tf.updateTF(TF.fromJson(msg));
    _tryUpdateRobotPose();
  }

  /// Look up a transform between two frames.
  RobotPose lookUpTransform(String targetFrame, String sourceFrame) {
    return _tf.lookUpForTransform(targetFrame, sourceFrame);
  }

  void _tryUpdateRobotPose() {
    final now = DateTime.now();
    if (now.difference(_lastPoseUpdate) < _poseUpdateInterval) return;
    _lastPoseUpdate = now;

    try {
      final rawPose = _tf.lookUpForTransform(
        globalSetting.mapFrameName,
        globalSetting.baseLinkFrameName,
      );

      // Skip zero poses (TF not ready)
      if (rawPose.x == 0 && rawPose.y == 0 && rawPose.theta == 0 &&
          _lastValidPose != null) {
        return;
      }

      final pose = _smoothPose(rawPose);
      robotPoseMap.value = pose;

      if (_mapNotifier != null && _mapNotifier!.value.data.isNotEmpty) {
        final poseScene = _mapNotifier!.value
            .xy2idx(vm.Vector2(pose.x, pose.y));
        robotPoseScene.value =
            RobotPose(poseScene.x, poseScene.y, pose.theta);
      }
    } catch (e) {
      // TF not yet available – this is normal during startup
      AppLogger.d('Robot pose TF not available yet', tag: _tag);
    }
  }

  /// Applies outlier rejection and EMA smoothing to prevent sudden jumps.
  RobotPose _smoothPose(RobotPose rawPose) {
    if (_lastValidPose == null) {
      _lastValidPose = rawPose;
      _rejectedCount = 0;
      return rawPose;
    }

    final dx = rawPose.x - _lastValidPose!.x;
    final dy = rawPose.y - _lastValidPose!.y;
    final distance = sqrt(dx * dx + dy * dy);

    // Reject large jumps unless we've rejected too many in a row
    // (which means the robot actually relocated, e.g. AMCL converged)
    if (distance > _maxJumpDistance && _rejectedCount < _maxRejectedCount) {
      _rejectedCount++;
      AppLogger.d(
        'Pose jump rejected: ${distance.toStringAsFixed(3)}m '
        '(rejected $_rejectedCount/$_maxRejectedCount)',
        tag: _tag,
      );
      return _lastValidPose!;
    }

    _rejectedCount = 0;

    // EMA smoothing
    final smoothX =
        _lastValidPose!.x + _smoothingAlpha * (rawPose.x - _lastValidPose!.x);
    final smoothY =
        _lastValidPose!.y + _smoothingAlpha * (rawPose.y - _lastValidPose!.y);
    // Smooth theta using circular interpolation
    final smoothTheta = _lerpAngle(
        _lastValidPose!.theta, rawPose.theta, _smoothingAlpha);

    final smoothed = RobotPose(smoothX, smoothY, smoothTheta);
    _lastValidPose = smoothed;
    return smoothed;
  }

  /// Interpolates between two angles handling wrap-around.
  double _lerpAngle(double from, double to, double t) {
    var diff = to - from;
    // Normalize to [-pi, pi]
    while (diff > pi) diff -= 2 * pi;
    while (diff < -pi) diff += 2 * pi;
    return from + t * diff;
  }
}
