import 'package:flutter/foundation.dart';
import 'package:ros_flutter_gui_app/app/logging/app_logger.dart';
import 'package:ros_flutter_gui_app/basic/RobotPose.dart';
import 'package:ros_flutter_gui_app/basic/action_status.dart';
import 'package:ros_flutter_gui_app/basic/occupancy_map.dart';
import 'package:ros_flutter_gui_app/basic/robot_path.dart';
import 'package:ros_flutter_gui_app/basic/transform.dart';
import 'package:ros_flutter_gui_app/global/setting.dart';
import 'package:ros_flutter_gui_app/provider/tf_service.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

/// Handles navigation-related ROS topic callbacks: local/global/trace paths
/// and navigation action status.
class NavigationDataService {
  static const String _tag = 'NavData';

  final TfService _tfService;

  final ValueNotifier<List<vm.Vector2>> localPath = ValueNotifier([]);
  final ValueNotifier<List<vm.Vector2>> globalPath = ValueNotifier([]);
  final ValueNotifier<List<vm.Vector2>> tracePath = ValueNotifier([]);
  final ValueNotifier<ActionStatus> navStatus =
      ValueNotifier(ActionStatus.unknown);

  /// Reference to the map for coordinate conversions.
  ValueNotifier<OccupancyMap>? _mapNotifier;

  // Throttle local path updates (high frequency during navigation)
  DateTime? _lastLocalPathTime;
  static const _localPathInterval = Duration(milliseconds: 200); // ~5Hz max

  NavigationDataService({required TfService tfService})
      : _tfService = tfService;

  void bindMap(ValueNotifier<OccupancyMap> mapNotifier) {
    _mapNotifier = mapNotifier;
  }

  // --- Path callbacks ---

  Future<void> localPathCallback(Map<String, dynamic> msg) async {
    // Throttle local path updates - arrives frequently during navigation
    final now = DateTime.now();
    if (_lastLocalPathTime != null &&
        now.difference(_lastLocalPathTime!) < _localPathInterval) {
      return;
    }
    _lastLocalPathTime = now;
    localPath.value = _parsePath(msg, 'local path');
  }

  Future<void> globalPathCallback(Map<String, dynamic> msg) async {
    globalPath.value = _parsePath(msg, 'global path');
  }

  Future<void> tracePathCallback(Map<String, dynamic> msg) async {
    tracePath.value = _parsePath(msg, 'trace path');
  }

  List<vm.Vector2> _parsePath(Map<String, dynamic> msg, String label) {
    try {
      final path = RobotPath.fromJson(msg);
      final frameId = path.header!.frameId!;

      RobotPose transPose;
      try {
        transPose = _tfService.lookUpTransform(
            globalSetting.mapFrameName, frameId);
      } catch (e) {
        AppLogger.d('No $label transform from map to $frameId', tag: _tag);
        return [];
      }

      if (_mapNotifier == null) return [];

      final newPath = <vm.Vector2>[];
      for (final pose in path.poses!) {
        final tran = RosTransform(
          translation: pose.pose!.position!,
          rotation: pose.pose!.orientation!,
        );
        final poseFrame = tran.getRobotPose();
        final poseMap = absoluteSum(transPose, poseFrame);
        final poseScene =
            _mapNotifier!.value.xy2idx(vm.Vector2(poseMap.x, poseMap.y));
        newPath.add(vm.Vector2(poseScene.x, poseScene.y));
      }
      return newPath;
    } catch (e) {
      AppLogger.e('Error parsing $label', tag: _tag, error: e);
      return [];
    }
  }

  // --- Navigation status ---

  Future<void> navStatusCallback(Map<String, dynamic> msg) async {
    try {
      final goalStatusArray = GoalStatusArray.fromJson(msg);
      if (goalStatusArray.statusList.isNotEmpty) {
        navStatus.value = goalStatusArray.statusList.last.status;
      }
    } catch (e) {
      AppLogger.e('Error parsing nav status', tag: _tag, error: e);
    }
  }

  /// Reset all navigation data.
  void reset() {
    localPath.value = [];
    globalPath.value = [];
    tracePath.value = [];
    navStatus.value = ActionStatus.unknown;
  }
}
