import 'dart:ui';
import 'package:flame/components.dart';
import 'package:flutter/material.dart';
import 'package:ros_flutter_gui_app/basic/pointcloud2.dart';
import 'package:ros_flutter_gui_app/basic/occupancy_map.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

class PointCloudComponent extends Component {
  List<Point3D> pointList = [];
  OccupancyMap map;
  List<Offset> _cachedOffsets = [];

  // Cache paint to avoid allocation every frame
  final Paint _paint = Paint()
    ..color = Colors.orange
    ..strokeCap = StrokeCap.round
    ..strokeWidth = 1;

  PointCloudComponent({required this.pointList, required this.map});

  void updateMap(OccupancyMap newMap) {
    map = newMap;
    _transformPoints();
  }

  void updatePoints(List<Point3D> newPoints) {
    pointList = newPoints;
    _transformPoints();
  }

  void _transformPoints() {
    if (map.mapConfig.resolution <= 0 || map.mapConfig.height <= 0) {
      _cachedOffsets = [];
      return;
    }
    if (pointList.isEmpty) {
      _cachedOffsets = [];
      return;
    }

    final offsets = <Offset>[];
    for (final point in pointList) {
      final mapPoint = map.xy2idx(vm.Vector2(point.x, point.y));
      if (mapPoint.x.isFinite && mapPoint.y.isFinite) {
        offsets.add(Offset(mapPoint.x, mapPoint.y));
      }
    }
    _cachedOffsets = offsets;
  }

  bool get hasLayout => true;

  @override
  void onMount() {
    super.onMount();
    _transformPoints();
  }

  @override
  void render(Canvas canvas) {
    if (_cachedOffsets.isEmpty) return;
    canvas.drawPoints(PointMode.points, _cachedOffsets, _paint);
  }
}
