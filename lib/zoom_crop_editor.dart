import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';

import 'card_corner_detector.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ZoomCropEditor
//
// Replaces SecondStageCropOverlay. Shows the cropped card image with:
//   • Purple outer guide = final crop boundary
//   • Green  inner guide = card content boundary (margin reference)
//   • Corner + edge drag handles on BOTH boxes
//   • Magnifier loupe that appears while dragging any handle
//   • "Auto-detect corners" button that runs CardCornerDetector
// ─────────────────────────────────────────────────────────────────────────────

class ZoomCropEditor extends StatefulWidget {
  final String imagePath;
  final Size imageCoordinateSize; // pixel size of the cropped image file
  final DetectedCardCorners initialCorners;
  final ValueChanged<Rect> onOuterRectChanged;
  final ValueChanged<Rect> onInnerRectChanged;
  final Future<void> Function()? onAutoSnap;

  const ZoomCropEditor({
    super.key,
    required this.imagePath,
    required this.imageCoordinateSize,
    required this.initialCorners,
    required this.onOuterRectChanged,
    required this.onInnerRectChanged,
    this.onAutoSnap,
  });

  @override
  State<ZoomCropEditor> createState() => _ZoomCropEditorState();
}

class _ZoomCropEditorState extends State<ZoomCropEditor>
    with SingleTickerProviderStateMixin {
  // Guide rects in image-pixel coordinates
  late Rect _outerRect;
  late Rect _innerRect;

  // Loupe (magnifier)
  bool _showLoupe = false;
  Offset _loupeCenter = Offset.zero; // in image-pixel coords
  late AnimationController _loupeAnim;

  static const double _minGap = 10.0;
  static const double _innerPad = 18.0; // inner is 18px inside outer
  static const double _handleSize = 52.0;

  @override
  void initState() {
    super.initState();
    _loupeAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _initRects();
  }

  void _initRects() {
    final bounds = widget.imageCoordinateSize;
    final inflated = widget.initialCorners.inflate(6, bounds);
    _outerRect = inflated.boundingRect;
    if (_outerRect.width < _minGap * 3 || _outerRect.height < _minGap * 3) {
      _outerRect = Rect.fromLTWH(
        bounds.width * 0.08,
        bounds.height * 0.08,
        bounds.width * 0.84,
        bounds.height * 0.84,
      );
    }
    _innerRect = _outerRect.deflate(_innerPad);
    _clampInner();

    // Notify parent of initial values
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onOuterRectChanged(_outerRect);
      widget.onInnerRectChanged(_innerRect);
    });
  }

  void _clampInner() {
    _innerRect = Rect.fromLTRB(
      (_innerRect.left).clamp(_outerRect.left + _minGap,
          _outerRect.right - _minGap * 2),
      (_innerRect.top).clamp(_outerRect.top + _minGap,
          _outerRect.bottom - _minGap * 2),
      (_innerRect.right).clamp(_outerRect.left + _minGap * 2,
          _outerRect.right - _minGap),
      (_innerRect.bottom).clamp(_outerRect.top + _minGap * 2,
          _outerRect.bottom - _minGap),
    );
  }

  // ── Rect setters that also notify parent ──────────────────────────
  void _setOuter(Rect r) {
    setState(() => _outerRect = r);
    widget.onOuterRectChanged(r);
  }

  void _setInner(Rect r) {
    _innerRect = r;
    _clampInner();
    setState(() {});
    widget.onInnerRectChanged(_innerRect);
  }

  Future<void> _resetToDetected() async {
    if (widget.onAutoSnap != null) {
      await widget.onAutoSnap!();
      return;
    }
    setState(_initRects);
  }

  // ── Loupe helpers ────────────────────────────────────────────────
  void _startLoupe(Offset imageCoord) {
    setState(() {
      _showLoupe = true;
      _loupeCenter = imageCoord;
    });
    _loupeAnim.forward();
  }

  void _moveLoupe(Offset imageCoord) {
    setState(() => _loupeCenter = imageCoord);
  }

  void _endLoupe() {
    _loupeAnim.reverse().then((_) {
      if (mounted) setState(() => _showLoupe = false);
    });
  }

  // ── Coordinate converters (widget ↔ image-pixel) ─────────────────
  // These are computed inside build() once we know the display rect.
  // Passed into the builder so handles can use them.
  double _dxToImage(double ddx, Rect displayRect) =>
      ddx * widget.imageCoordinateSize.width / displayRect.width;

  double _dyToImage(double ddy, Rect displayRect) =>
      ddy * widget.imageCoordinateSize.height / displayRect.height;

  @override
  void dispose() {
    _loupeAnim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      // Compute how the image is displayed (BoxFit.contain)
      final imgSize = widget.imageCoordinateSize;
      final scale = math.min(
        constraints.maxWidth / imgSize.width,
        constraints.maxHeight / imgSize.height,
      );
      final displayW = imgSize.width * scale;
      final displayH = imgSize.height * scale;
      final displayRect = Rect.fromLTWH(
        (constraints.maxWidth - displayW) / 2,
        (constraints.maxHeight - displayH) / 2,
        displayW,
        displayH,
      );

      // Convert rects to display coords for painting
      final outerD = Rect.fromLTRB(
        displayRect.left + _outerRect.left * scale,
        displayRect.top + _outerRect.top * scale,
        displayRect.left + _outerRect.right * scale,
        displayRect.top + _outerRect.bottom * scale,
      );
      final innerD = Rect.fromLTRB(
        displayRect.left + _innerRect.left * scale,
        displayRect.top + _innerRect.top * scale,
        displayRect.left + _innerRect.right * scale,
        displayRect.top + _innerRect.bottom * scale,
      );

      return Stack(clipBehavior: Clip.none, children: [
        // ── Image ──────────────────────────────────────────────────
        Positioned(
          left: displayRect.left,
          top: displayRect.top,
          width: displayRect.width,
          height: displayRect.height,
          child: Image.file(
            File(widget.imagePath),
            fit: BoxFit.fill,
          ),
        ),

        // ── Semi-transparent outside overlay ───────────────────────
        Positioned.fill(
          child: CustomPaint(
            painter: _DimOutsidePainter(outerD),
          ),
        ),

        // ── Guide box borders ──────────────────────────────────────
        Positioned.fill(
          child: CustomPaint(
            painter: _GuideRectsPainter(outerD, innerD),
          ),
        ),

        // ── Drag handles: OUTER (purple) ───────────────────────────
        ..._buildOuterHandles(displayRect, scale),

        // ── Drag handles: INNER (green) ────────────────────────────
        ..._buildInnerHandles(displayRect, scale),

        // ── Loupe magnifier ────────────────────────────────────────
        if (_showLoupe)
          _LoupeOverlay(
            imagePath: widget.imagePath,
            imageSize: imgSize,
            focalPointInImage: _loupeCenter,
            displayRect: displayRect,
            animation: _loupeAnim,
          ),

        // ── Auto-detect button ─────────────────────────────────────
        Positioned(
          bottom: 12,
          right: 12,
          child: _AutoDetectButton(onTap: () => _resetToDetected()),
        ),
      ]);
    });
  }

  // ── Handle builders ───────────────────────────────────────────────

  List<Widget> _buildOuterHandles(Rect displayRect, double scale) {
    final purple = Colors.deepPurpleAccent;
    return [
      // TL corner
      _cornerHandle(
        display: Offset(
          displayRect.left + _outerRect.left * scale,
          displayRect.top + _outerRect.top * scale,
        ),
        color: purple,
        onUpdate: (d) {
          final dx = _dxToImage(d.delta.dx, displayRect);
          final dy = _dyToImage(d.delta.dy, displayRect);
          _setOuter(Rect.fromLTRB(
            (_outerRect.left + dx).clamp(0, _outerRect.right - _minGap),
            (_outerRect.top + dy).clamp(0, _outerRect.bottom - _minGap),
            _outerRect.right,
            _outerRect.bottom,
          ));
          _moveLoupe(Offset(_outerRect.left, _outerRect.top));
        },
        onStart: (_) => _startLoupe(Offset(_outerRect.left, _outerRect.top)),
        onEnd: (_) => _endLoupe(),
      ),
      // TR corner
      _cornerHandle(
        display: Offset(
          displayRect.left + _outerRect.right * scale,
          displayRect.top + _outerRect.top * scale,
        ),
        color: purple,
        onUpdate: (d) {
          final dx = _dxToImage(d.delta.dx, displayRect);
          final dy = _dyToImage(d.delta.dy, displayRect);
          _setOuter(Rect.fromLTRB(
            _outerRect.left,
            (_outerRect.top + dy).clamp(0, _outerRect.bottom - _minGap),
            (_outerRect.right + dx).clamp(
                _outerRect.left + _minGap, widget.imageCoordinateSize.width),
            _outerRect.bottom,
          ));
          _moveLoupe(Offset(_outerRect.right, _outerRect.top));
        },
        onStart: (_) => _startLoupe(Offset(_outerRect.right, _outerRect.top)),
        onEnd: (_) => _endLoupe(),
      ),
      // BR corner
      _cornerHandle(
        display: Offset(
          displayRect.left + _outerRect.right * scale,
          displayRect.top + _outerRect.bottom * scale,
        ),
        color: purple,
        onUpdate: (d) {
          final dx = _dxToImage(d.delta.dx, displayRect);
          final dy = _dyToImage(d.delta.dy, displayRect);
          _setOuter(Rect.fromLTRB(
            _outerRect.left,
            _outerRect.top,
            (_outerRect.right + dx).clamp(
                _outerRect.left + _minGap, widget.imageCoordinateSize.width),
            (_outerRect.bottom + dy).clamp(_outerRect.top + _minGap,
                widget.imageCoordinateSize.height),
          ));
          _moveLoupe(Offset(_outerRect.right, _outerRect.bottom));
        },
        onStart: (_) =>
            _startLoupe(Offset(_outerRect.right, _outerRect.bottom)),
        onEnd: (_) => _endLoupe(),
      ),
      // BL corner
      _cornerHandle(
        display: Offset(
          displayRect.left + _outerRect.left * scale,
          displayRect.top + _outerRect.bottom * scale,
        ),
        color: purple,
        onUpdate: (d) {
          final dx = _dxToImage(d.delta.dx, displayRect);
          final dy = _dyToImage(d.delta.dy, displayRect);
          _setOuter(Rect.fromLTRB(
            (_outerRect.left + dx).clamp(0, _outerRect.right - _minGap),
            _outerRect.top,
            _outerRect.right,
            (_outerRect.bottom + dy).clamp(_outerRect.top + _minGap,
                widget.imageCoordinateSize.height),
          ));
          _moveLoupe(Offset(_outerRect.left, _outerRect.bottom));
        },
        onStart: (_) =>
            _startLoupe(Offset(_outerRect.left, _outerRect.bottom)),
        onEnd: (_) => _endLoupe(),
      ),
      // Top-edge midpoint
      _edgeHandle(
        display: Offset(
          displayRect.left +
              (_outerRect.left + _outerRect.right) / 2 * scale,
          displayRect.top + _outerRect.top * scale,
        ),
        icon: Icons.keyboard_arrow_up,
        color: purple,
        onUpdate: (d) {
          final dy = _dyToImage(d.delta.dy, displayRect);
          _setOuter(Rect.fromLTRB(
            _outerRect.left,
            (_outerRect.top + dy).clamp(0, _innerRect.top - _minGap),
            _outerRect.right,
            _outerRect.bottom,
          ));
        },
      ),
      // Bottom-edge midpoint
      _edgeHandle(
        display: Offset(
          displayRect.left +
              (_outerRect.left + _outerRect.right) / 2 * scale,
          displayRect.top + _outerRect.bottom * scale,
        ),
        icon: Icons.keyboard_arrow_down,
        color: purple,
        onUpdate: (d) {
          final dy = _dyToImage(d.delta.dy, displayRect);
          _setOuter(Rect.fromLTRB(
            _outerRect.left,
            _outerRect.top,
            _outerRect.right,
            (_outerRect.bottom + dy).clamp(_innerRect.bottom + _minGap,
                widget.imageCoordinateSize.height),
          ));
        },
      ),
      // Left-edge midpoint
      _edgeHandle(
        display: Offset(
          displayRect.left + _outerRect.left * scale,
          displayRect.top +
              (_outerRect.top + _outerRect.bottom) / 2 * scale,
        ),
        icon: Icons.keyboard_arrow_left,
        color: purple,
        onUpdate: (d) {
          final dx = _dxToImage(d.delta.dx, displayRect);
          _setOuter(Rect.fromLTRB(
            (_outerRect.left + dx).clamp(0, _innerRect.left - _minGap),
            _outerRect.top,
            _outerRect.right,
            _outerRect.bottom,
          ));
        },
      ),
      // Right-edge midpoint
      _edgeHandle(
        display: Offset(
          displayRect.left + _outerRect.right * scale,
          displayRect.top +
              (_outerRect.top + _outerRect.bottom) / 2 * scale,
        ),
        icon: Icons.keyboard_arrow_right,
        color: purple,
        onUpdate: (d) {
          final dx = _dxToImage(d.delta.dx, displayRect);
          _setOuter(Rect.fromLTRB(
            _outerRect.left,
            _outerRect.top,
            (_outerRect.right + dx).clamp(_innerRect.right + _minGap,
                widget.imageCoordinateSize.width),
            _outerRect.bottom,
          ));
        },
      ),
    ];
  }

  List<Widget> _buildInnerHandles(Rect displayRect, double scale) {
    final green = Colors.green;
    return [
      // Top edge
      _edgeHandle(
        display: Offset(
          displayRect.left +
              (_innerRect.left + _innerRect.right) / 2 * scale,
          displayRect.top + _innerRect.top * scale,
        ),
        icon: Icons.keyboard_arrow_up,
        color: green,
        onUpdate: (d) {
          final dy = _dyToImage(d.delta.dy, displayRect);
          _setInner(Rect.fromLTRB(
            _innerRect.left,
            (_innerRect.top + dy)
                .clamp(_outerRect.top + _minGap, _innerRect.bottom - _minGap),
            _innerRect.right,
            _innerRect.bottom,
          ));
        },
      ),
      // Bottom edge
      _edgeHandle(
        display: Offset(
          displayRect.left +
              (_innerRect.left + _innerRect.right) / 2 * scale,
          displayRect.top + _innerRect.bottom * scale,
        ),
        icon: Icons.keyboard_arrow_down,
        color: green,
        onUpdate: (d) {
          final dy = _dyToImage(d.delta.dy, displayRect);
          _setInner(Rect.fromLTRB(
            _innerRect.left,
            _innerRect.top,
            _innerRect.right,
            (_innerRect.bottom + dy).clamp(
                _innerRect.top + _minGap, _outerRect.bottom - _minGap),
          ));
        },
      ),
      // Left edge
      _edgeHandle(
        display: Offset(
          displayRect.left + _innerRect.left * scale,
          displayRect.top +
              (_innerRect.top + _innerRect.bottom) / 2 * scale,
        ),
        icon: Icons.keyboard_arrow_left,
        color: green,
        onUpdate: (d) {
          final dx = _dxToImage(d.delta.dx, displayRect);
          _setInner(Rect.fromLTRB(
            (_innerRect.left + dx)
                .clamp(_outerRect.left + _minGap, _innerRect.right - _minGap),
            _innerRect.top,
            _innerRect.right,
            _innerRect.bottom,
          ));
        },
      ),
      // Right edge
      _edgeHandle(
        display: Offset(
          displayRect.left + _innerRect.right * scale,
          displayRect.top +
              (_innerRect.top + _innerRect.bottom) / 2 * scale,
        ),
        icon: Icons.keyboard_arrow_right,
        color: green,
        onUpdate: (d) {
          final dx = _dxToImage(d.delta.dx, displayRect);
          _setInner(Rect.fromLTRB(
            _innerRect.left,
            _innerRect.top,
            (_innerRect.right + dx).clamp(
                _innerRect.left + _minGap, _outerRect.right - _minGap),
            _innerRect.bottom,
          ));
        },
      ),
    ];
  }

  // ── Handle widget factories ───────────────────────────────────────

  Widget _cornerHandle({
    required Offset display,
    required Color color,
    required GestureDragUpdateCallback onUpdate,
    required GestureDragStartCallback onStart,
    required GestureDragEndCallback onEnd,
  }) {
    const size = 36.0;
    return Positioned(
      left: display.dx - size / 2,
      top: display.dy - size / 2,
      child: GestureDetector(
        onPanStart: onStart,
        onPanUpdate: onUpdate,
        onPanEnd: onEnd,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(color: Colors.black45, blurRadius: 6)],
          ),
        ),
      ),
    );
  }

  Widget _edgeHandle({
    required Offset display,
    required IconData icon,
    required Color color,
    required GestureDragUpdateCallback onUpdate,
  }) {
    const size = _handleSize;
    return Positioned(
      left: display.dx - size / 2,
      top: display.dy - size / 2,
      child: GestureDetector(
        onPanUpdate: onUpdate,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(10),
            boxShadow: [BoxShadow(color: Colors.black45, blurRadius: 6)],
          ),
          child: Icon(icon, color: Colors.white, size: 32),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _DimOutsidePainter — darkens area outside the outer guide rect
// ─────────────────────────────────────────────────────────────────────────────
class _DimOutsidePainter extends CustomPainter {
  final Rect outerRect;
  _DimOutsidePainter(this.outerRect);

  @override
  void paint(Canvas canvas, Size size) {
    final fullPath = Path()..addRect(Offset.zero & size);
    final holePath = Path()
      ..addRRect(RRect.fromRectAndRadius(outerRect, const Radius.circular(4)));
    final dimPath =
        Path.combine(PathOperation.difference, fullPath, holePath);
    canvas.drawPath(
        dimPath, Paint()..color = Colors.black.withValues(alpha: 0.45));
  }

  @override
  bool shouldRepaint(_DimOutsidePainter old) => old.outerRect != outerRect;
}

// ─────────────────────────────────────────────────────────────────────────────
// _GuideRectsPainter — draws outer (purple) and inner (green) guide borders
// ─────────────────────────────────────────────────────────────────────────────
class _GuideRectsPainter extends CustomPainter {
  final Rect outerRect;
  final Rect innerRect;
  _GuideRectsPainter(this.outerRect, this.innerRect);

  @override
  void paint(Canvas canvas, Size size) {
    // Outer: purple dashed
    final outerPaint = Paint()
      ..color = Colors.deepPurpleAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawRRect(
      RRect.fromRectAndRadius(outerRect, const Radius.circular(4)),
      outerPaint,
    );

    // Corner brackets on outer rect
    _drawCornerBrackets(canvas, outerRect, Colors.deepPurpleAccent, 22);

    // Inner: green solid
    canvas.drawRRect(
      RRect.fromRectAndRadius(innerRect, const Radius.circular(4)),
      Paint()
        ..color = Colors.green
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  void _drawCornerBrackets(
      Canvas canvas, Rect rect, Color color, double len) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;

    // TL
    canvas.drawLine(rect.topLeft, rect.topLeft + Offset(len, 0), p);
    canvas.drawLine(rect.topLeft, rect.topLeft + Offset(0, len), p);
    // TR
    canvas.drawLine(rect.topRight, rect.topRight + Offset(-len, 0), p);
    canvas.drawLine(rect.topRight, rect.topRight + Offset(0, len), p);
    // BR
    canvas.drawLine(rect.bottomRight, rect.bottomRight + Offset(-len, 0), p);
    canvas.drawLine(rect.bottomRight, rect.bottomRight + Offset(0, -len), p);
    // BL
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft + Offset(len, 0), p);
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft + Offset(0, -len), p);
  }

  @override
  bool shouldRepaint(_GuideRectsPainter old) =>
      old.outerRect != outerRect || old.innerRect != innerRect;
}

// ─────────────────────────────────────────────────────────────────────────────
// _LoupeOverlay — magnifier that appears when dragging a corner handle
// ─────────────────────────────────────────────────────────────────────────────
class _LoupeOverlay extends StatelessWidget {
  final String imagePath;
  final Size imageSize;
  final Offset focalPointInImage; // in image-pixel coords
  final Rect displayRect; // where image is rendered on screen
  final AnimationController animation;

  static const double loupeSize = 140.0;
  static const double zoomFactor = 3.0;

  const _LoupeOverlay({
    required this.imagePath,
    required this.imageSize,
    required this.focalPointInImage,
    required this.displayRect,
    required this.animation,
  });

  @override
  Widget build(BuildContext context) {
    // Position loupe above the focal point
    final scale = displayRect.width / imageSize.width;
    final focalDisplay = Offset(
      displayRect.left + focalPointInImage.dx * scale,
      displayRect.top + focalPointInImage.dy * scale,
    );

    final loupeLeft =
        (focalDisplay.dx - loupeSize / 2).clamp(0.0, double.infinity);
    final loupeTop = math.max(8.0, focalDisplay.dy - loupeSize - 20);

    // The zoomed view is implemented as an oversized clipped image
    // shifted so the focal point is centered inside the loupe.
    final zoomedW = imageSize.width * scale * zoomFactor;
    final zoomedH = imageSize.height * scale * zoomFactor;
    final shiftX =
        loupeSize / 2 - focalPointInImage.dx * scale * zoomFactor;
    final shiftY =
        loupeSize / 2 - focalPointInImage.dy * scale * zoomFactor;

    return Positioned(
      left: loupeLeft,
      top: loupeTop,
      child: FadeTransition(
        opacity: animation,
        child: Container(
          width: loupeSize,
          height: loupeSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 12)],
          ),
          clipBehavior: Clip.hardEdge,
          child: OverflowBox(
            maxWidth: double.infinity,
            maxHeight: double.infinity,
            child: Transform.translate(
              offset: Offset(shiftX, shiftY),
              child: Image.file(
                File(imagePath),
                width: zoomedW,
                height: zoomedH,
                fit: BoxFit.fill,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _AutoDetectButton — teal pill that resets guides to detector output
// ─────────────────────────────────────────────────────────────────────────────
class _AutoDetectButton extends StatelessWidget {
  final VoidCallback onTap;
  const _AutoDetectButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.tealAccent.shade700,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: Colors.black45, blurRadius: 6)],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.auto_fix_high, color: Colors.white, size: 16),
            SizedBox(width: 6),
            Text('Auto-snap',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}
