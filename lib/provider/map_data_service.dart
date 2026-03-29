import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:ros_flutter_gui_app/app/logging/app_logger.dart';
import 'package:ros_flutter_gui_app/app/services/performance_monitor.dart';
import 'package:ros_flutter_gui_app/basic/RobotPose.dart';
import 'package:ros_flutter_gui_app/basic/math.dart';
import 'package:ros_flutter_gui_app/basic/occupancy_map.dart';
import 'package:ros_flutter_gui_app/basic/topology_map.dart';
import 'package:ros_flutter_gui_app/global/setting.dart';
import 'package:ros_flutter_gui_app/provider/connection_service.dart';
import 'package:ros_flutter_gui_app/provider/map_manager.dart';
import 'package:ros_flutter_gui_app/provider/tf_service.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

/// Parameters for costmap overlay isolate computation.
class _CostmapOverlayParams {
  final int globalWidth, globalHeight;
  final int localWidth, localHeight;
  final double mapOX, mapOY;
  final List<List<int>> localData;

  _CostmapOverlayParams({
    required this.globalWidth,
    required this.globalHeight,
    required this.localWidth,
    required this.localHeight,
    required this.mapOX,
    required this.mapOY,
    required this.localData,
  });
}

/// Result from costmap overlay computation – flat array of overlay cells.
class _CostmapOverlayResult {
  // Sparse representation: [row, col, value, row, col, value, ...]
  final Int32List cells;
  _CostmapOverlayResult(this.cells);
}

/// Top-level function for compute() – runs costmap overlay in isolate.
_CostmapOverlayResult _computeCostmapOverlay(_CostmapOverlayParams p) {
  final cells = <int>[];
  final ox = p.mapOX.toInt();
  final oy = p.mapOY.toInt();

  for (int x = 0; x < p.localHeight; x++) {
    final gx = ox + x;
    if (gx < 0 || gx >= p.globalHeight) continue;
    for (int y = 0; y < p.localWidth; y++) {
      final gy = oy + y;
      if (gy < 0 || gy >= p.globalWidth) continue;
      final value = p.localData[x][y];
      if (value != 0) {
        cells.add(gx);
        cells.add(gy);
        cells.add(value);
      }
    }
  }
  return _CostmapOverlayResult(Int32List.fromList(cells));
}

/// Handles map-related ROS topic callbacks: occupancy grid, costmaps,
/// and topology map.
class MapDataService {
  static const String _tag = 'MapData';

  final ConnectionService _connection;
  final TfService _tfService;
  final MapManager mapManager;

  // Costmap notifiers
  final ValueNotifier<OccupancyMap> localCostmap =
      ValueNotifier(OccupancyMap());
  final ValueNotifier<OccupancyMap> globalCostmap =
      ValueNotifier(OccupancyMap());

  // Delegates to MapManager
  ValueNotifier<OccupancyMap> get map => mapManager.occupancyMap;
  ValueNotifier<TopologyMap> get topologyMap => mapManager.topologyMap;

  // Throttle costmap updates
  DateTime? _lastCostmapTime;

  // Guard against overlapping costmap processing
  bool _localCostmapProcessing = false;

  MapDataService({
    required ConnectionService connection,
    required TfService tfService,
    required this.mapManager,
  })  : _connection = connection,
        _tfService = tfService;

  // --- Occupancy grid ---

  Future<void> mapCallback(Map<String, dynamic> msg) async {
    final sw = Stopwatch()..start();

    final map = OccupancyMap();
    map.mapConfig.resolution = msg['info']['resolution'];
    map.mapConfig.width = msg['info']['width'];
    map.mapConfig.height = msg['info']['height'];
    map.mapConfig.originX = msg['info']['origin']['position']['x'];
    map.mapConfig.originY = msg['info']['origin']['position']['y'];

    final dataList = List<int>.from(msg['data']);
    map.data = List.generate(
      map.mapConfig.height,
      (i) => List.generate(map.mapConfig.width, (j) => 0),
    );
    for (int i = 0; i < dataList.length; i++) {
      map.data[i ~/ map.mapConfig.width][i % map.mapConfig.width] = dataList[i];
    }
    map.setFlip();
    mapManager.updateOccupancyMapFromRos(map);

    sw.stop();
    PerformanceMonitor().recordMapRenderTime(sw.elapsed);
    AppLogger.d(
      'Map updated ${map.mapConfig.width}x${map.mapConfig.height} '
      'in ${sw.elapsedMilliseconds}ms',
      tag: _tag,
    );
  }

  // --- Local costmap ---

  Future<void> localCostmapCallback(Map<String, dynamic> msg) async {
    if (!_shouldProcessCostmap()) return;
    if (_localCostmapProcessing) return;
    _localCostmapProcessing = true;

    try {
      final width = msg['info']['width'] as int;
      final height = msg['info']['height'] as int;
      final resolution = msg['info']['resolution'] as double;
      final originX = msg['info']['origin']['position']['x'] as double;
      final originY = msg['info']['origin']['position']['y'] as double;

      final orientation = msg['info']['origin']['orientation'];
      final qx = (orientation['x'] as num?)?.toDouble() ?? 0.0;
      final qy = (orientation['y'] as num?)?.toDouble() ?? 0.0;
      final qz = (orientation['z'] as num?)?.toDouble() ?? 0.0;
      final qw = (orientation['w'] as num?)?.toDouble() ?? 1.0;

      final quaternion = vm.Quaternion(qx, qy, qz, qw);
      final euler = quaternionToEuler(quaternion);
      final originTheta = euler[0];

      final costmap = OccupancyMap();
      costmap.mapConfig
        ..resolution = resolution
        ..width = width
        ..height = height
        ..originX = originX
        ..originY = originY;

      final dataList = List<int>.from(msg['data']);
      costmap.data = List.generate(
        height,
        (i) => List.generate(width, (j) => 0),
      );
      for (int i = 0; i < dataList.length; i++) {
        costmap.data[i ~/ width][i % width] = dataList[i];
      }
      costmap.setFlip();

      final frameId = msg['header']['frame_id'] as String;
      RobotPose originPose;
      try {
        final transPose = _tfService.lookUpTransform(
            globalSetting.mapFrameName, frameId);
        final localOrigin = RobotPose(originX, originY, originTheta);
        final mapOrigin = absoluteSum(transPose, localOrigin);
        mapOrigin.y += costmap.heightMap();
        originPose = mapOrigin;
      } catch (e) {
        AppLogger.d('No local costmap transform for $frameId', tag: _tag);
        return;
      }

      // Compute overlay in isolate instead of blocking main thread
      final globalMap = map.value;
      final occPoint =
          globalMap.xy2idx(vm.Vector2(originPose.x, originPose.y));

      final result = await compute(
        _computeCostmapOverlay,
        _CostmapOverlayParams(
          globalWidth: globalMap.mapConfig.width,
          globalHeight: globalMap.mapConfig.height,
          localWidth: costmap.mapConfig.width,
          localHeight: costmap.mapConfig.height,
          mapOX: occPoint.x,
          mapOY: occPoint.y,
          localData: costmap.data,
        ),
      );

      // Build the sized costmap from sparse result
      final sizedCostMap = globalMap.copy();
      sizedCostMap.setZero();

      final cells = result.cells;
      for (int i = 0; i < cells.length; i += 3) {
        final gx = cells[i];
        final gy = cells[i + 1];
        final value = cells[i + 2];
        if (gy < sizedCostMap.data.length && gx < sizedCostMap.data[gy].length) {
          sizedCostMap.data[gy][gx] = value;
        }
      }

      localCostmap.value = sizedCostMap;
    } catch (e) {
      AppLogger.e('Error processing local costmap', tag: _tag, error: e);
    } finally {
      _localCostmapProcessing = false;
    }
  }

  // --- Global costmap ---

  Future<void> globalCostmapCallback(Map<String, dynamic> msg) async {
    if (!_shouldProcessCostmap()) return;

    try {
      final width = msg['info']['width'] as int;
      final height = msg['info']['height'] as int;
      final resolution = msg['info']['resolution'] as double;
      final originX = msg['info']['origin']['position']['x'] as double;
      final originY = msg['info']['origin']['position']['y'] as double;

      final costmap = OccupancyMap();
      costmap.mapConfig
        ..resolution = resolution
        ..width = width
        ..height = height
        ..originX = originX
        ..originY = originY;

      final dataList = List<int>.from(msg['data']);
      costmap.data = List.generate(
        height,
        (i) => List.generate(width, (j) => 0),
      );
      for (int i = 0; i < dataList.length; i++) {
        costmap.data[i ~/ width][i % width] = dataList[i];
      }
      costmap.setFlip();

      globalCostmap.value = costmap;
    } catch (e) {
      AppLogger.e('Error processing global costmap', tag: _tag, error: e);
    }
  }

  // --- Topology map ---

  Future<void> topologyMapCallback(Map<String, dynamic> msg) async {
    await Future.delayed(const Duration(seconds: 1));

    try {
      final topMap = TopologyMap.fromJson(msg);
      AppLogger.i(
        'Received topology map: ${topMap.points.length} points, '
        '${topMap.routes.length} routes',
        tag: _tag,
      );
      mapManager.updateTopologyMapFromRos(topMap);
    } catch (e) {
      AppLogger.e('Error processing topology map', tag: _tag, error: e);
    }
  }

  Future<void> updateTopologyMap(TopologyMap updatedMap) async {
    mapManager.updateTopologyMap(updatedMap);
    try {
      _connection.publish(
          '${globalSetting.topologyMapTopic}/update', updatedMap.toJson());
      AppLogger.i(
        'Topology map published: ${updatedMap.points.length} points, '
        '${updatedMap.routes.length} routes',
        tag: _tag,
      );
    } catch (e) {
      AppLogger.e('Failed to publish topology map', tag: _tag, error: e);
    }
  }

  Future<void> publishOccupancyGrid() async {
    final mapData = map.value.copy();
    if (mapData.data.isEmpty) {
      AppLogger.w('Map data empty, cannot publish', tag: _tag);
      return;
    }
    mapData.setFlip();

    try {
      final now = DateTime.now();
      final timestamp = {
        'sec': now.millisecondsSinceEpoch ~/ 1000,
        'nanosec': (now.millisecondsSinceEpoch % 1000) * 1000000,
      };

      final flatData = <int>[];
      for (int row = 0; row < mapData.Rows(); row++) {
        for (int col = 0; col < mapData.Cols(); col++) {
          flatData.add(mapData.data[row][col]);
        }
      }

      final msg = {
        'header': {'stamp': timestamp, 'frame_id': 'map'},
        'info': {
          'map_load_time': timestamp,
          'resolution': mapData.mapConfig.resolution,
          'width': mapData.mapConfig.width,
          'height': mapData.mapConfig.height,
          'origin': {
            'position': {
              'x': mapData.mapConfig.originX,
              'y': mapData.mapConfig.originY,
              'z': 0.0,
            },
            'orientation': {'x': 0.0, 'y': 0.0, 'z': 0.0, 'w': 1.0},
          },
        },
        'data': flatData,
      };

      _connection.publish('/map/update', msg);
      AppLogger.i(
        'Occupancy grid published: '
        '${mapData.mapConfig.width}x${mapData.mapConfig.height}',
        tag: _tag,
      );
    } catch (e) {
      AppLogger.e('Failed to publish occupancy grid', tag: _tag, error: e);
    }
  }

  // --- Costmap throttle ---

  bool _shouldProcessCostmap() {
    final now = DateTime.now();
    if (_lastCostmapTime != null &&
        now.difference(_lastCostmapTime!).inSeconds < 5) {
      return false;
    }
    _lastCostmapTime = now;
    return true;
  }

  /// Reset costmap data.
  void reset() {
    localCostmap.value = OccupancyMap();
    globalCostmap.value = OccupancyMap();
  }
}
