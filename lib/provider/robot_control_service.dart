import 'dart:async';
import 'package:ros_flutter_gui_app/app/logging/app_logger.dart';
import 'package:ros_flutter_gui_app/basic/RobotPose.dart';
import 'package:ros_flutter_gui_app/basic/math.dart';
import 'package:ros_flutter_gui_app/global/setting.dart';
import 'package:ros_flutter_gui_app/provider/connection_service.dart';

/// Handles all robot command publishing: speed control, navigation goals,
/// relocalization, and emergency stop.
class RobotControlService {
  static const String _tag = 'RobotControl';

  final ConnectionService _connection;

  Timer? _cmdVelTimer;
  double _cmdVx = 0;
  double _cmdVy = 0;
  double _cmdVw = 0;

  RobotControlService(this._connection);

  // --- Speed control ---

  void setVx(double vx) => _cmdVx = vx;
  void setVy(double vy) => _cmdVy = vy;
  void setVw(double vw) => _cmdVw = vw;

  void startManualCtrl() {
    _cmdVelTimer?.cancel();
    _cmdVelTimer =
        Timer.periodic(const Duration(milliseconds: 100), (_) async {
      await sendSpeed(_cmdVx, _cmdVy, _cmdVw);
    });
    AppLogger.d('Manual control started', tag: _tag);
  }

  void stopManualCtrl() {
    _cmdVelTimer?.cancel();
    _cmdVelTimer = null;
    _cmdVx = 0;
    _cmdVy = 0;
    _cmdVw = 0;
    sendSpeed(0, 0, 0);
    AppLogger.d('Manual control stopped', tag: _tag);
  }

  Future<void> sendSpeed(double vx, double vy, double vw) async {
    final msg = {
      'linear': {'x': vx, 'y': vy, 'z': 0.0},
      'angular': {'x': 0.0, 'y': 0.0, 'z': vw},
    };
    try {
      _connection.publish(globalSetting.getConfig('SpeedCtrlTopic'), msg);
    } catch (e) {
      AppLogger.e('Failed to send speed command', tag: _tag, error: e);
    }
  }

  Future<void> sendEmergencyStop() async {
    await sendSpeed(0, 0, 0);
    AppLogger.w('Emergency stop sent', tag: _tag);
  }

  // --- Navigation ---

  Future<void> sendNavigationGoal(RobotPose pose) async {
    final quaternion = eulerToQuaternion(pose.theta, 0, 0);
    final msg = {
      'header': {
        'stamp': _buildRosTimestamp(),
        'frame_id': globalSetting.mapFrameName,
      },
      'pose': {
        'position': {'x': pose.x, 'y': pose.y, 'z': 0},
        'orientation': {
          'x': quaternion.x,
          'y': quaternion.y,
          'z': quaternion.z,
          'w': quaternion.w,
        },
      },
    };
    try {
      _connection.publish(globalSetting.navGoalTopic, msg);
      AppLogger.i('Navigation goal sent: (${pose.x}, ${pose.y})', tag: _tag);
    } catch (e) {
      AppLogger.e('Failed to send navigation goal', tag: _tag, error: e);
    }
  }

  Future<void> sendCancelNav() async {
    try {
      _connection.publish('${globalSetting.navGoalTopic}/cancel', {});
      AppLogger.i('Navigation cancelled', tag: _tag);
    } catch (e) {
      AppLogger.e('Failed to cancel navigation', tag: _tag, error: e);
    }
  }

  Future<Map<String, dynamic>> sendTopologyGoal(String name) async {
    final msg = {'point_name': name};
    try {
      final result =
          await _connection.callService('/nav_to_topology_point', msg);
      if (result is String) {
        return {'is_success': false, 'message': result};
      }
      AppLogger.i('Topology goal sent: $name', tag: _tag);
      return result as Map<String, dynamic>;
    } catch (e) {
      AppLogger.e('Topology goal failed', tag: _tag, error: e);
      return {'is_success': false, 'message': e.toString()};
    }
  }

  // --- Relocalization ---

  Future<void> sendRelocPose(RobotPose pose) async {
    final quaternion = eulerToQuaternion(pose.theta, 0, 0);
    final msg = {
      'header': {
        'stamp': _buildRosTimestamp(),
        'frame_id': globalSetting.mapFrameName,
      },
      'pose': {
        'pose': {
          'position': {'x': pose.x, 'y': pose.y, 'z': 0},
          'orientation': {
            'x': quaternion.x,
            'y': quaternion.y,
            'z': quaternion.z,
            'w': quaternion.w,
          },
        },
        'covariance': [
          0.1, 0, 0, 0, 0, 0,
          0, 0.1, 0, 0, 0, 0,
          0, 0, 0.1, 0, 0, 0,
          0, 0, 0, 0.1, 0, 0,
          0, 0, 0, 0, 0.1, 0,
          0, 0, 0, 0, 0, 0.1,
        ],
      },
    };
    try {
      _connection.publish(globalSetting.relocTopic, msg);
      AppLogger.i('Reloc pose sent: (${pose.x}, ${pose.y})', tag: _tag);
    } catch (e) {
      AppLogger.e('Failed to send reloc pose', tag: _tag, error: e);
    }
  }

  // --- Helpers ---

  Map<String, dynamic> _buildRosTimestamp() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    return {
      'secs': nowMs ~/ 1000,
      'nsecs': (nowMs % 1000) * 1000000,
    };
  }

  /// Reset speed command state.
  void resetCmdVel() {
    _cmdVx = 0;
    _cmdVy = 0;
    _cmdVw = 0;
  }

  void dispose() {
    _cmdVelTimer?.cancel();
    _cmdVelTimer = null;
  }
}
