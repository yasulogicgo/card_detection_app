import 'package:card_detacstion_app/api_card_detection.dart';
import 'package:flutter/material.dart';

/// Draws a 4-corner card border in image pixel coordinates.
class CardCornerBorderPainter extends CustomPainter {
  final List<Offset> corners;

  const CardCornerBorderPainter({required this.corners});

  @override
  void paint(Canvas canvas, Size size) {
    if (corners.length != 4) return;

    final path = Path()
      ..moveTo(corners[0].dx, corners[0].dy)
      ..lineTo(corners[1].dx, corners[1].dy)
      ..lineTo(corners[2].dx, corners[2].dy)
      ..lineTo(corners[3].dx, corners[3].dy)
      ..close();

    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF3DDC84)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant CardCornerBorderPainter oldDelegate) =>
      oldDelegate.corners != corners;
}

/// Draws API outer bounding box + corner polygon in image pixel coordinates.
class ApiDetectionOverlayPainter extends CustomPainter {
  final ApiCardDetection detection;
  final bool cornersOnly;

  const ApiDetectionOverlayPainter({
    required this.detection,
    this.cornersOnly = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final corners = detection.corners;
    if (cornersOnly && corners.length == 4) {
      CardCornerBorderPainter(corners: corners).paint(canvas, size);
      return;
    }

    final outer = detection.outerBox;
    if (outer != null && !cornersOnly) {
      canvas.drawRect(
        outer,
        Paint()
          ..color = const Color(0xFF7B61FF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4,
      );
    }

    if (corners.length == 4) {
      CardCornerBorderPainter(corners: corners).paint(canvas, size);
    }
  }

  @override
  bool shouldRepaint(covariant ApiDetectionOverlayPainter oldDelegate) =>
      oldDelegate.detection.outerBox != detection.outerBox ||
      oldDelegate.detection.corners != detection.corners ||
      oldDelegate.cornersOnly != cornersOnly;
}
