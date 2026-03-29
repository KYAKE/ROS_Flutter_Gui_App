import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:ros_flutter_gui_app/app/logging/app_logger.dart';
import 'package:ros_flutter_gui_app/basic/RobotPose.dart';
import 'package:ros_flutter_gui_app/basic/action_status.dart';
import 'package:ros_flutter_gui_app/basic/diagnostic_array.dart';
import 'package:ros_flutter_gui_app/basic/occupancy_map.dart';
import 'package:ros_flutter_gui_app/basic/pointcloud2.dart';
import 'package:ros_flutter_gui_app/basic/topology_map.dart';
import 'package:ros_flutter_gui_app/global/setting.dart';
import 'package:ros_flutter_gui_app/provider/connection_service.dart';
import 'package:ros_flutter_gui_app/provider/diagnostic_manager.dart';
import 'package:ros_flutter_gui_app/provider/map_data_service.dart';
import 'package:ros_flutter_gui_app/provider/map_manager.dart';
import 'package:ros_flutter_gui_app/provider/navigation_data_service.dart';
import 'package:ros_flutter_gui_app/provider/robot_control_service.dart';
import 'package:ros_flutter_gui_app/provider/ros_bridge_player.dart';
import 'package:ros_flutter_gui_app/provider/sensor_data_service.dart';
import 'package:ros_flutter_gui_app/provider/tf_service.dart';
import 'package:roslibdart/roslibdart.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

// Re-export data classes so existing imports keep working.
export 'package:ros_flutter_gui_app/provider/sensor_data_service.dart'
    show LaserData, RobotSpeed;

/// Backward-compatible facade that delegates to focused services.
///
/// All existing code that depends on [RosChannel] continues to work unchanged.
/// Internally, responsibilities are split across:
///   - [ConnectionService]       – connection lifecycle & exponential backoff
///   - [TfService]               – TF management & event-driven pose updates
///   - [RobotControlService]     – speed / navigation / reloc commands
///   - [SensorDataService]       – laser, odom, battery, pointcloud, diagnostics
///   - [MapDataService]          – map, costmap, topology
///   - [NavigationDataService]   – paths & nav status
class RosChannel {
  static const String _tag = 'RosChannel';

  // --- Internal services ---
  late final ConnectionService _connectionService;
  late final TfService _tfService;
  late final RobotControlService _robotControl;
  late final SensorDataService _sensorData;
  late final MapDataService _mapData;
  late final NavigationDataService _navData;

  // --- Public sub-objects (kept for backward compat) ---
  late MapManager mapManager;
  late DiagnosticManager diagnosticManager;

  // ========== Backward-compatible public fields ==========

  // Connection
  String get rosUrl_ => _connectionService.currentUrl;
  bool get isReconnect_ => _connectionService.currentUrl.isNotEmpty;
  bool manualCtrlMode_ = false;

  Status get rosConnectState_ => _connectionService.status;
  set rosConnectState_(Status s) => _connectionService.connectionState.value = s;

  // RosBridgePlayer (for code that accesses it directly)
  RosBridgePlayer get rosBridgePlayer => _connectionService.rosBridgePlayer;

  // Sensor data
  ValueNotifier<double> get battery_ => _sensorData.battery;
  ValueNotifier<Uint8List> get imageData => _sensorData.imageData;
  ValueNotifier<RobotSpeed> get robotSpeed_ => _sensorData.robotSpeed;
  ValueNotifier<List<vm.Vector2>> get laserBasePoint_ =>
      _sensorData.laserBasePoint;
  ValueNotifier<LaserData> get laserPointData => _sensorData.laserPointData;
  ValueNotifier<List<vm.Vector2>> get robotFootprint =>
      _sensorData.robotFootprint;
  ValueNotifier<List<Point3D>> get pointCloud2Data =>
      _sensorData.pointCloud2Data;
  ValueNotifier<DiagnosticArray> get diagnosticData =>
      _sensorData.diagnosticData;

  // Map data
  ValueNotifier<OccupancyMap> get map_ => _mapData.map;
  ValueNotifier<TopologyMap> get topologyMap_ => _mapData.topologyMap;
  ValueNotifier<OccupancyMap> get localCostmap => _mapData.localCostmap;
  ValueNotifier<OccupancyMap> get globalCostmap => _mapData.globalCostmap;

  // Navigation data
  ValueNotifier<List<vm.Vector2>> get localPath => _navData.localPath;
  ValueNotifier<List<vm.Vector2>> get globalPath => _navData.globalPath;
  ValueNotifier<List<vm.Vector2>> get tracePath => _navData.tracePath;
  ValueNotifier<ActionStatus> get navStatus_ => _navData.navStatus;

  // TF / pose
  ValueNotifier<RobotPose> get robotPoseMap => _tfService.robotPoseMap;
  ValueNotifier<RobotPose> get robotPoseScene => _tfService.robotPoseScene;

  // Topic accessors
  ValueNotifier<OccupancyMap> get map => map_;
  List<TopicWithSchemaName> get topics => _connectionService.topics;
  Map<String, dynamic> get datatypes => _connectionService.datatypes;
  int get currentRosVersion => _connectionService.currentRosVersion;

  void refreshTopics() => _connectionService.refreshTopics();

  // Speed command state (exposed for gamepad_widget backward compat)
  RobotSpeed get cmdVel_ => RobotSpeed(vx: 0, vy: 0, vw: 0);

  // ========== Constructor ==========

  RosChannel() {
    diagnosticManager = DiagnosticManager();
    mapManager = MapManager();
    mapManager.init();

    _connectionService = ConnectionService();
    _tfService = TfService();
    _sensorData = SensorDataService(
      tfService: _tfService,
      diagnosticManager: diagnosticManager,
    );
    _mapData = MapDataService(
      connection: _connectionService,
      tfService: _tfService,
      mapManager: mapManager,
    );
    _navData = NavigationDataService(tfService: _tfService);
    _robotControl = RobotControlService(_connectionService);

    // Bind map reference for coordinate conversions
    _tfService.bindMap(_mapData.map);
    _sensorData.bindMap(_mapData.map);
    _navData.bindMap(_mapData.map);

    // Wire up connection callbacks
    _connectionService.onConnected = _onConnected;

    globalSetting.init().then((_) {
      AppLogger.i('Global settings initialized', tag: _tag);
    });
  }

  void _onConnected() {
    // Small delay to let the connection stabilize
    Future.delayed(const Duration(seconds: 1), () async {
      await initChannel();
    });
  }

  // ========== Connection ==========

  Future<String> connect(String url) async {
    return _connectionService.connect(url);
  }

  void closeConnection() {
    _sensorData.reset();
    _navData.reset();
    _mapData.reset();
    _robotControl.resetCmdVel();
    _tfService.resetSmoothing();
    _tfService.robotPoseMap.value = RobotPose.zero();
    _tfService.robotPoseScene.value = RobotPose.zero();
    _connectionService.close();
    AppLogger.i('All connections closed and state reset', tag: _tag);
  }

  void destroyConnection() => closeConnection();

  // ========== Channel initialization ==========

  Future<void> initChannel() async {
    final conn = _connectionService;

    // Subscriptions — sensor
    conn.subscribe(globalSetting.laserTopic, 'sensor_msgs/LaserScan',
        _sensorData.laserCallback);
    conn.subscribe(_resolveOdometryTopic(), 'nav_msgs/Odometry',
        _sensorData.odomCallback);
    conn.subscribe(globalSetting.batteryTopic, 'sensor_msgs/BatteryState',
        _sensorData.batteryCallback);
    conn.subscribe(globalSetting.robotFootprintTopic,
        'geometry_msgs/PolygonStamped', _sensorData.robotFootprintCallback);
    conn.subscribe(globalSetting.pointCloud2Topic,
        'sensor_msgs/PointCloud2', _sensorData.pointCloud2Callback);
    conn.subscribe(globalSetting.diagnosticTopic,
        'diagnostic_msgs/DiagnosticArray', _sensorData.diagnosticCallback);

    // Subscriptions — TF
    conn.subscribe('/tf', 'tf2_msgs/TFMessage', _tfService.handleTfMessage);
    conn.subscribe(
        '/tf_static', 'tf2_msgs/TFMessage', _tfService.handleTfStaticMessage);

    // Subscriptions — map
    conn.subscribe(globalSetting.mapTopic, 'nav_msgs/OccupancyGrid',
        _mapData.mapCallback);
    conn.subscribe(globalSetting.localCostmapTopic,
        'nav_msgs/OccupancyGrid', _mapData.localCostmapCallback);
    conn.subscribe(globalSetting.globalCostmapTopic,
        'nav_msgs/OccupancyGrid', _mapData.globalCostmapCallback);
    conn.subscribe(globalSetting.topologyMapTopic,
        'topology_msgs/TopologyMap', _mapData.topologyMapCallback);

    // Subscriptions — navigation
    conn.subscribe(globalSetting.localPathTopic, 'nav_msgs/Path',
        _navData.localPathCallback);
    conn.subscribe(globalSetting.globalPathTopic, 'nav_msgs/Path',
        _navData.globalPathCallback);
    conn.subscribe(globalSetting.tracePathTopic, 'nav_msgs/Path',
        _navData.tracePathCallback);
    conn.subscribe(globalSetting.navToPoseStatusTopic,
        'action_msgs/GoalStatusArray', _navData.navStatusCallback);
    conn.subscribe(globalSetting.navThroughPosesStatusTopic,
        'action_msgs/GoalStatusArray', _navData.navStatusCallback);

    // Advertise publishers
    conn.advertise(
        globalSetting.relocTopic, 'geometry_msgs/PoseWithCovarianceStamped');
    conn.advertise(globalSetting.navGoalTopic, 'geometry_msgs/PoseStamped');
    conn.advertise('${globalSetting.navGoalTopic}/cancel', 'std_msgs/Empty');
    conn.advertise('${globalSetting.topologyMapTopic}/update',
        'topology_msgs/TopologyMap');
    conn.advertise('/map/update', 'nav_msgs/OccupancyGrid');
    conn.advertise(
        globalSetting.getConfig('SpeedCtrlTopic'), 'geometry_msgs/Twist');

    AppLogger.i('All ROS channels initialized', tag: _tag);
  }

  // ========== Robot control (delegated) ==========

  void setVx(double vx) => _robotControl.setVx(vx);
  void setVy(double vy) => _robotControl.setVy(vy);
  void setVw(double vw) => _robotControl.setVw(vw);

  // Keep old misspelled name for backward compat
  void startMunalCtrl() => _robotControl.startManualCtrl();
  void stopMunalCtrl() => _robotControl.stopManualCtrl();

  Future<void> sendSpeed(double vx, double vy, double vw) =>
      _robotControl.sendSpeed(vx, vy, vw);

  Future<void> sendEmergencyStop() => _robotControl.sendEmergencyStop();

  Future<void> sendNavigationGoal(RobotPose pose) =>
      _robotControl.sendNavigationGoal(pose);

  Future<void> sendCancelNav() => _robotControl.sendCancelNav();

  Future<Map<String, dynamic>> sendTopologyGoal(String name) =>
      _robotControl.sendTopologyGoal(name);

  Future<void> sendRelocPose(RobotPose pose) {
    _tfService.resetSmoothing();
    return _robotControl.sendRelocPose(pose);
  }

  // ========== Map operations (delegated) ==========

  Future<void> updateTopologyMap(TopologyMap updatedMap) =>
      _mapData.updateTopologyMap(updatedMap);

  Future<void> publishOccupancyGrid() => _mapData.publishOccupancyGrid();

  // ========== Topic resolution ==========

  String _resolveOdometryTopic() {
    final configuredTopic = globalSetting.odomTopic.trim();
    final availableTopics = _connectionService.topics;
    final availableNames = availableTopics.map((t) => t.name).toSet();

    if (availableNames.contains(configuredTopic)) return configuredTopic;

    const fallbacks = [
      '/odom',
      '/wheel/odometry',
      '/platform/odom/filtered',
      '/odometry/filtered',
      '/odom/filtered',
    ];

    for (final topic in fallbacks) {
      if (availableNames.contains(topic)) {
        AppLogger.w(
          "Odom topic '$configuredTopic' not found, fallback to '$topic'",
          tag: _tag,
        );
        return topic;
      }
    }

    for (final topic in availableTopics) {
      if (topic.schemaName.contains('Odometry')) {
        AppLogger.w(
          "Odom topic '$configuredTopic' not found, "
          "fallback to '${topic.name}'",
          tag: _tag,
        );
        return topic.name;
      }
    }

    return configuredTopic;
  }
}
