import 'dart:ui';
import 'package:flame/components.dart';
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

class PathComponent extends Component with HasGameRef {
  List<vm.Vector2> pointList = [];
  Color color = Colors.green;
  late Timer animationTimer;
  double animationValue = 0.0;

  PathComponent({
    required this.pointList,
    required this.color,
  });

  @override
  Future<void> onLoad() async {
    animationTimer = Timer(
      2.0,
      onTick: () {
        animationValue = 0.0;
      },
      repeat: true,
    );
    add(PathRenderer(
      pointList: pointList,
      color: color,
      animationValue: animationValue,
    ));
  }

  @override
  void update(double dt) {
    animationTimer.update(dt);
    animationValue = (animationTimer.progress * 2.0) % 1.0;

    final renderer = children.whereType<PathRenderer>().firstOrNull;
    if (renderer != null) {
      renderer.updateAnimationValue(animationValue);
    }

    super.update(dt);
  }

  void updatePath(List<vm.Vector2> newPoints) {
    pointList = newPoints;
    final renderer = children.whereType<PathRenderer>().firstOrNull;
    if (renderer != null) {
      renderer.updatePath(newPoints);
    }
  }

  @override
  void onRemove() {
    super.onRemove();
  }
}

/// Pre-computed arrow positioned along a path segment.
class _ArrowSlot {
  final double cx, cy; // triangle center
  final double dx, dy; // direction (normalized)
  final double px, py; // perpendicular
  final double opacity;

  const _ArrowSlot(
      this.cx, this.cy, this.dx, this.dy, this.px, this.py, this.opacity);
}

class PathRenderer extends Component with HasGameRef {
  List<vm.Vector2> pointList = [];
  Color color;
  double animationValue;

  // Cached geometry – rebuilt only when pointList changes.
  Path? _cachedLinePath;
  List<_ArrowSlot> _arrowSlots = const [];
  late Paint _linePaint;
  late Paint _arrowPaint;
  bool _geometryDirty = true;

  PathRenderer({
    required this.pointList,
    required this.color,
    required this.animationValue,
  }) {
    _linePaint = Paint()
      ..color = color.withOpacity(0.6)
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    _arrowPaint = Paint()
      ..color = color.withOpacity(0.7)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.fill;
  }

  void updatePath(List<vm.Vector2> newPoints) {
    pointList = newPoints;
    _geometryDirty = true;
  }

  void updateAnimationValue(double newValue) {
    animationValue = newValue;
  }

  // Rebuild cached line path and arrow slot positions.
  void _rebuildGeometry() {
    _geometryDirty = false;
    if (pointList.length < 2) {
      _cachedLinePath = null;
      _arrowSlots = const [];
      return;
    }

    // Build line path once
    final path = Path();
    path.moveTo(pointList[0].x, pointList[0].y);
    for (int i = 1; i < pointList.length; i++) {
      path.lineTo(pointList[i].x, pointList[i].y);
    }
    _cachedLinePath = path;

    // Downsample: for very long paths, only process every Nth segment
    final segCount = pointList.length - 1;
    final step = segCount > 200 ? (segCount ~/ 200).clamp(1, 10) : 1;

    const arrowSpacing = 12.0;
    const triangleSize = 2.0;

    final slots = <_ArrowSlot>[];
    for (int i = 0; i < segCount; i += step) {
      final sx = pointList[i].x;
      final sy = pointList[i].y;
      final ex = pointList[i + 1].x;
      final ey = pointList[i + 1].y;

      final ddx = ex - sx;
      final ddy = ey - sy;
      final dist = (ddx * ddx + ddy * ddy);
      if (dist < arrowSpacing * arrowSpacing) continue; // segment too short
      final len = _sqrt(dist);
      final ndx = ddx / len;
      final ndy = ddy / len;
      final px = -ndy;
      final py = ndx;

      // Place arrow slots at fixed intervals along this segment
      double d = arrowSpacing;
      while (d < len - triangleSize) {
        final cx = sx + ndx * d;
        final cy = sy + ndy * d;
        final ratio = d / len;
        final opacity = (0.8 - ratio * 0.3).clamp(0.0, 1.0);
        slots.add(_ArrowSlot(cx, cy, ndx, ndy, px, py, opacity));
        d += arrowSpacing;
      }
    }
    _arrowSlots = slots;
  }

  static double _sqrt(double v) {
    // fast enough for our purposes
    double x = v;
    double y = 1.0;
    const e = 0.001;
    while (x - y > e) {
      x = (x + y) / 2;
      y = v / x;
    }
    return x;
  }

  @override
  void render(Canvas canvas) {
    if (!isMounted) return;
    try {
      if (pointList.isEmpty || pointList.length < 2) return;

      if (_geometryDirty) _rebuildGeometry();

      // Draw cached line path
      if (_cachedLinePath != null) {
        canvas.drawPath(_cachedLinePath!, _linePaint);
      }

      // Draw pre-computed arrows with animation offset
      _drawArrows(canvas);
    } catch (e) {
      // silently ignore render errors
    }
  }

  void _drawArrows(Canvas canvas) {
    if (_arrowSlots.isEmpty) return;

    const triangleSize = 2.0;
    const halfSize = triangleSize * 0.5;
    // Animation shifts arrow positions slightly for flow effect
    const arrowSpacing = 12.0;
    final offset = animationValue * arrowSpacing;

    final path = Path();
    for (final slot in _arrowSlots) {
      // Shift center by animation offset along direction
      final cx = slot.cx + slot.dx * offset;
      final cy = slot.cy + slot.dy * offset;

      // Front tip
      final fx = cx + slot.dx * triangleSize;
      final fy = cy + slot.dy * triangleSize;
      // Left rear
      final lx = cx - slot.dx * halfSize + slot.px * halfSize;
      final ly = cy - slot.dy * halfSize + slot.py * halfSize;
      // Right rear
      final rx = cx - slot.dx * halfSize - slot.px * halfSize;
      final ry = cy - slot.dy * halfSize - slot.py * halfSize;

      path.moveTo(fx, fy);
      path.lineTo(lx, ly);
      path.lineTo(rx, ry);
      path.close();
    }
    // Single draw call for all arrows with uniform color
    _arrowPaint.color = color.withOpacity(0.7);
    canvas.drawPath(path, _arrowPaint);
  }
}
