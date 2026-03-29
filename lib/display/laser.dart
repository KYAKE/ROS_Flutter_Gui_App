import 'dart:ui';
import 'package:flame/components.dart';
import 'package:flutter/material.dart';

class LaserComponent extends Component {
  List<Vector2> pointList = [];
  // Cache paint and offset list to avoid allocations every frame
  final Paint _paint = Paint()
    ..color = Colors.redAccent
    ..strokeCap = StrokeCap.round
    ..strokeWidth = 1;
  List<Offset> _cachedOffsets = [];
  bool _dirty = false;

  LaserComponent({required this.pointList});

  void updateLaser(List<Vector2> newPoints) {
    pointList = newPoints;
    _dirty = true;
  }

  bool get hasLayout => true;

  @override
  void render(Canvas canvas) {
    if (pointList.isEmpty) return;

    if (_dirty) {
      _dirty = false;
      _cachedOffsets = List<Offset>.generate(
        pointList.length,
        (i) {
          final p = pointList[i];
          return (p.x.isFinite && p.y.isFinite) ? Offset(p.x, p.y) : Offset.zero;
        },
        growable: false,
      );
    }

    if (_cachedOffsets.isEmpty) return;
    canvas.drawPoints(PointMode.points, _cachedOffsets, _paint);
  }
}
