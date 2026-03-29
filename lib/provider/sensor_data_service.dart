import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:ros_flutter_gui_app/app/logging/app_logger.dart';
import 'package:ros_flutter_gui_app/basic/RobotPose.dart';
import 'package:ros_flutter_gui_app/basic/diagnostic_array.dart';
import 'package:ros_flutter_gui_app/basic/laser_scan.dart';
import 'package:ros_flutter_gui_app/basic/pointcloud2.dart';
import 'package:ros_flutter_gui_app/basic/polygon_stamped.dart';
import 'package:ros_flutter_gui_app/basic/occupancy_map.dart';
import 'package:ros_flutter_gui_app/global/setting.dart';
import 'package:ros_flutter_gui_app/provider/diagnostic_manager.dart';
import 'package:ros_flutter_gui_app/provider/tf_service.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

/// Data class for laser scan data bundled with the robot pose at scan time.
class LaserData {
  RobotPose robotPose;
  List<vm.Vector2> laserPoseBaseLink;
  LaserData({required this.robotPose, required this.laserPoseBaseLink});
}

/// Data class for robot velocity.
class RobotSpeed {
  double vx;
  double vy;
  double vw;
  RobotSpeed({required this.vx, required this.vy, required this.vw});
}

/// Parameters passed to the laser compute isolate.
class _LaserComputeParams {
  final double angleMin;
  final double angleIncrement;
  final List<double> ranges;
  final double basePoseX, basePoseY, basePoseTheta;

  _LaserComputeParams({
    required this.angleMin,
    required this.angleIncrement,
    required this.ranges,
    required this.basePoseX,
    required this.basePoseY,
    required this.basePoseTheta,
  });
}

/// Result from the laser compute isolate.
class _LaserComputeResult {
  final Float64List points; // x0,y0,x1,y1,...

  _LaserComputeResult(this.points);
}

/// Top-level function for compute() – runs laser trig math in isolate.
_LaserComputeResult _computeLaserPoints(_LaserComputeParams params) {
  final cosBase = cos(params.basePoseTheta);
  final sinBase = sin(params.basePoseTheta);

  final result = <double>[];
  for (int i = 0; i < params.ranges.length; i++) {
    final range = params.ranges[i];
    if (range.isInfinite || range.isNaN || range == -1) continue;

    final angle = params.angleMin + i * params.angleIncrement;
    // Laser point in laser frame
    final lx = range * cos(angle);
    final ly = range * sin(angle);
    // Transform to base_link frame: absoluteSum(basePose, laserPose)
    final bx = params.basePoseX + lx * cosBase - ly * sinBase;
    final by = params.basePoseY + lx * sinBase + ly * cosBase;
    result.add(bx);
    result.add(by);
  }
  return _LaserComputeResult(Float64List.fromList(result));
}

/// Handles all sensor data callbacks: laser, odometry, battery, point cloud,
/// robot footprint, and diagnostics.
class SensorDataService {
  static const String _tag = 'SensorData';

  final TfService _tfService;
  final DiagnosticManager diagnosticManager;

  // Sensor value notifiers
  final ValueNotifier<double> battery = ValueNotifier(78);
  final ValueNotifier<Uint8List> imageData = ValueNotifier(Uint8List(0));
  final ValueNotifier<RobotSpeed> robotSpeed =
      ValueNotifier(RobotSpeed(vx: 0, vy: 0, vw: 0));
  final ValueNotifier<List<vm.Vector2>> laserBasePoint = ValueNotifier([]);
  final ValueNotifier<LaserData> laserPointData = ValueNotifier(
      LaserData(robotPose: RobotPose(0, 0, 0), laserPoseBaseLink: []));
  final ValueNotifier<List<vm.Vector2>> robotFootprint = ValueNotifier([]);
  final ValueNotifier<List<Point3D>> pointCloud2Data = ValueNotifier([]);
  final ValueNotifier<DiagnosticArray> diagnosticData =
      ValueNotifier(DiagnosticArray());

  /// Reference to the map for coordinate conversions.
  ValueNotifier<OccupancyMap>? _mapNotifier;

  // Throttle: laser display updates
  DateTime? _lastLaserTime;
  static const _laserInterval = Duration(milliseconds: 150); // ~7Hz max

  // Guard: prevent overlapping compute calls
  bool _laserProcessing = false;

  SensorDataService({
    required TfService tfService,
    required this.diagnosticManager,
  }) : _tfService = tfService;

  void bindMap(ValueNotifier<OccupancyMap> mapNotifier) {
    _mapNotifier = mapNotifier;
  }

  // --- Callbacks ---

  Future<void> batteryCallback(Map<String, dynamic> message) async {
    double percentage = message['percentage'] * 100;
    battery.value = percentage;
  }

  Future<void> odomCallback(Map<String, dynamic> message) async {
    try {
      double vx = message['twist']['twist']['linear']['x'];
      double vy = message['twist']['twist']['linear']['y'];
      double vw = message['twist']['twist']['angular']['z'];
      robotSpeed.value = RobotSpeed(vx: vx, vy: vy, vw: vw);
    } catch (e) {
      AppLogger.w('Failed to parse odometry', tag: _tag, error: e);
    }
  }

  Future<void> robotFootprintCallback(Map<String, dynamic> message) async {
    try {
      final polygonStamped = PolygonStamped.fromJson(message);
      final frameId = polygonStamped.header!.frameId!;

      RobotPose transPose;
      try {
        transPose = _tfService.lookUpTransform(
            globalSetting.mapFrameName, frameId);
      } catch (e) {
        AppLogger.d('No footprint transform from map to $frameId', tag: _tag);
        return;
      }

      final newPoints = <vm.Vector2>[];
      if (polygonStamped.polygon != null && _mapNotifier != null) {
        for (final point in polygonStamped.polygon!.points) {
          final pose = RobotPose(point.x, point.y, 0);
          final poseMap = absoluteSum(transPose, pose);
          final poseScene =
              _mapNotifier!.value.xy2idx(vm.Vector2(poseMap.x, poseMap.y));
          newPoints.add(poseScene);
        }
      }
      robotFootprint.value = newPoints;
    } catch (e) {
      AppLogger.e('Error parsing robot footprint', tag: _tag, error: e);
    }
  }

  Future<void> laserCallback(Map<String, dynamic> msg) async {
    // Throttle display updates
    final now = DateTime.now();
    if (_lastLaserTime != null &&
        now.difference(_lastLaserTime!) < _laserInterval) {
      return;
    }
    _lastLaserTime = now;

    if (_laserProcessing) return;
    _laserProcessing = true;

    try {
      final laser = LaserScan.fromJson(msg);
      RobotPose laserPoseBase;
      try {
        laserPoseBase = _tfService.lookUpTransform(
            globalSetting.baseLinkFrameName, laser.header!.frameId!);
      } catch (e) {
        AppLogger.d(
            'No laser transform to ${laser.header!.frameId!}', tag: _tag);
        return;
      }

      final angleMin = laser.angleMin!.toDouble();
      final angleIncrement = laser.angleIncrement!;
      final ranges =
          laser.ranges!.map((r) => r.toDouble()).toList(growable: false);

      // Offload trig math to isolate
      final result = await compute(
        _computeLaserPoints,
        _LaserComputeParams(
          angleMin: angleMin,
          angleIncrement: angleIncrement,
          ranges: ranges,
          basePoseX: laserPoseBase.x,
          basePoseY: laserPoseBase.y,
          basePoseTheta: laserPoseBase.theta,
        ),
      );

      // Convert flat array back to Vector2 list
      final points = result.points;
      final newLaserPoints = <vm.Vector2>[];
      for (int i = 0; i < points.length; i += 2) {
        newLaserPoints.add(vm.Vector2(points[i], points[i + 1]));
      }

      laserBasePoint.value = newLaserPoints;
      laserPointData.value = LaserData(
        robotPose: _tfService.robotPoseMap.value,
        laserPoseBaseLink: newLaserPoints,
      );
    } catch (e) {
      AppLogger.e('Error processing laser scan', tag: _tag, error: e);
    } finally {
      _laserProcessing = false;
    }
  }

  Future<void> pointCloud2Callback(Map<String, dynamic> msg) async {
    try {
      final pointCloud = PointCloud2.fromJson(msg);
      final frameId = pointCloud.header!.frameId!;

      RobotPose transPose;
      try {
        transPose = _tfService.lookUpTransform(
            globalSetting.mapFrameName, frameId);
      } catch (e) {
        AppLogger.d('No pointcloud transform to $frameId', tag: _tag);
        return;
      }

      final transformedPoints = <Point3D>[];
      for (final point in pointCloud.getPoints()) {
        final pointPose = RobotPose(point.x, point.y, 0);
        final mapPose = absoluteSum(transPose, pointPose);
        transformedPoints.add(Point3D(mapPose.x, mapPose.y, point.z));
      }

      pointCloud2Data.value = transformedPoints;
    } catch (e) {
      AppLogger.e('Error processing PointCloud2', tag: _tag, error: e);
    }
  }

  Future<void> diagnosticCallback(Map<String, dynamic> msg) async {
    try {
      final diagnosticArray = DiagnosticArray.fromJson(msg);
      diagnosticData.value = diagnosticArray;
      diagnosticManager.updateDiagnosticStates(diagnosticArray);
    } catch (e) {
      AppLogger.e('Error processing diagnostics', tag: _tag, error: e);
    }
  }

  /// Reset all sensor data to defaults.
  void reset() {
    robotFootprint.value = [];
    laserBasePoint.value = [];
    laserPointData.value =
        LaserData(robotPose: RobotPose.zero(), laserPoseBaseLink: []);
    robotSpeed.value = RobotSpeed(vx: 0, vy: 0, vw: 0);
    battery.value = 0;
    imageData.value = Uint8List(0);
    pointCloud2Data.value = [];
    diagnosticData.value = DiagnosticArray();
  }
}
