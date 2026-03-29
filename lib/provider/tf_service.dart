import 'dart:async';
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

  TF2Dart get tf => _tf;

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
      final pose = _tf.lookUpForTransform(
        globalSetting.mapFrameName,
        globalSetting.baseLinkFrameName,
      );
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
}
