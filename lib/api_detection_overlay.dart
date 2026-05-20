import 'package:card_detacstion_app/api_card_detection.dart';
import 'package:flutter/material.dart';

/// Draws API outer bounding box + corner polygon in image pixel coordinates.
class ApiDetectionOverlayPainter extends CustomPainter {
  final ApiCardDetection detection;

  const ApiDetectionOverlayPainter({required this.detection});

  @override
  void paint(Canvas canvas, Size size) {
    final outer = detection.outerBox;
    if (outer != null) {
      canvas.drawRect(
        outer,
        Paint()
          ..color = const Color(0xFF7B61FF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4,
      );
    }

    final corners = detection.corners;
    if (corners.length == 4) {
      final path = Path()
        ..moveTo(corners[0].dx, corners[0].dy)
        ..lineTo(corners[1].dx, corners[1].dy)
        ..lineTo(corners[2].dx, corners[2].dy)
        ..lineTo(corners[3].dx, corners[3].dy)
        ..close();

      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFF3DDC84).withValues(alpha: 0.15)
          ..style = PaintingStyle.fill,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFF3DDC84)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );

      final dotPaint = Paint()..color = Colors.orangeAccent;
      for (final p in corners) {
        canvas.drawCircle(p, 8, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant ApiDetectionOverlayPainter oldDelegate) =>
      oldDelegate.detection.outerBox != detection.outerBox ||
      oldDelegate.detection.corners != detection.corners;
}
