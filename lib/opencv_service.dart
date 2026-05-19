import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:opencv_dart/opencv_dart.dart' as cv;

class Detection {
  final double left;
  final double top;
  final double right;
  final double bottom;
  final double score;

  /// Normalized points (0 → 1)
  /// Order:
  /// TopLeft, TopRight, BottomRight, BottomLeft
  final List<Offset>? corners;

  Detection({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.score,
    this.corners,
  });
}

class OpenCvService {
  /// MAIN CARD DETECTION
  /// Returns accurate 4 corner points
  Detection refineDetectionOnImage(Uint8List imageBytes) {
    try {
      final decoded = img.decodeImage(imageBytes);
      if (decoded == null) {
        return _emptyDetection();
      }

      final baked = img.bakeOrientation(decoded);
      final orientedBytes = Uint8List.fromList(img.encodeJpg(baked, quality: 92));
      final mat = cv.imdecode(orientedBytes, cv.IMREAD_COLOR);

      if (mat.isEmpty) {
        return _emptyDetection();
      }

      final int imageW = mat.cols;
      final int imageH = mat.rows;

      // =========================================================
      // 1. RESIZE FOR FAST PROCESSING
      // =========================================================

      const int targetWidth = 700;

      final double resizeScale = targetWidth / imageW;

      final int resizedH = (imageH * resizeScale).toInt();

      final resized = cv.resize(mat, (targetWidth, resizedH));

      // =========================================================
      // 2. GRAYSCALE
      // =========================================================

      final gray = cv.cvtColor(resized, cv.COLOR_BGR2GRAY);

      // =========================================================
      // 3. REMOVE NOISE
      // =========================================================

      final blurred = cv.gaussianBlur(gray, (5, 5), 0);

      // =========================================================
      // 4. EDGE DETECTION
      // =========================================================

      final edges = cv.canny(blurred, 50, 150);

      // =========================================================
      // 5. CLOSE GAPS
      // =========================================================

      final kernel = cv.getStructuringElement(cv.MORPH_RECT, (5, 5));

      final closed = cv.morphologyEx(edges, cv.MORPH_CLOSE, kernel);

      // =========================================================
      // 6. FIND CONTOURS
      // =========================================================

      final (contours, _) = cv.findContours(
        closed,
        cv.RETR_EXTERNAL,
        cv.CHAIN_APPROX_SIMPLE,
      );

      if (contours.isEmpty) {
        return _emptyDetection();
      }

      cv.VecPoint? bestContour;

      double bestArea = 0;

      for (final contour in contours) {
        final double area = cv.contourArea(contour);

        // Ignore tiny objects
        if (area < (targetWidth * resizedH * 0.02)) {
          continue;
        }

        final double perimeter = cv.arcLength(contour, true);

        final approx = cv.approxPolyDP(contour, 0.02 * perimeter, true);

        // Must be rectangle
        if (approx.length != 4) {
          continue;
        }

        // Must be convex
        if (!cv.isContourConvex(approx)) {
          continue;
        }

        // Aspect ratio check
        final rect = cv.boundingRect(approx);

        final ratio = rect.width / rect.height;
        final normalizedRatio = ratio > 1.0 ? ratio : 1.0 / ratio;

        // Allow portrait and landscape card shapes
        if (normalizedRatio < 1.2 || normalizedRatio > 2.5) {
          continue;
        }

        if (area > bestArea) {
          bestArea = area;
          bestContour = approx;
        }
      }

      // =========================================================
      // 7. NO CARD FOUND
      // =========================================================

      if (bestContour == null) {
        return _emptyDetection();
      }

      // =========================================================
      // 8. CONVERT TO NORMALIZED POINTS
      // =========================================================

      final List<Offset> corners = [];

      for (int i = 0; i < 4; i++) {
        final p = bestContour[i];

        corners.add(Offset(p.x / targetWidth, p.y / resizedH));
      }

      final sortedCorners = _sortCorners(corners);

      // Bounding box
      final xs = sortedCorners.map((e) => e.dx).toList();
      final ys = sortedCorners.map((e) => e.dy).toList();

      return Detection(
        left: xs.reduce(math.min),
        top: ys.reduce(math.min),
        right: xs.reduce(math.max),
        bottom: ys.reduce(math.max),
        score: 1.0,
        corners: sortedCorners,
      );
    } catch (e) {
      debugPrint("OpenCV Detection Error: $e");
      return _emptyDetection();
    }
  }

  // =============================================================
  // PERSPECTIVE CROP
  // =============================================================

  Uint8List? getWarpedCard(
    Uint8List imageBytes,
    List<Offset> normalizedCorners,
  ) {
    try {
      final decoded = img.decodeImage(imageBytes);
      if (decoded == null) return null;
      final baked = img.bakeOrientation(decoded);
      final orientedBytes = Uint8List.fromList(img.encodeJpg(baked, quality: 92));
      final mat = cv.imdecode(orientedBytes, cv.IMREAD_COLOR);

      if (mat.isEmpty) {
        return null;
      }

      final int imageW = mat.cols;
      final int imageH = mat.rows;

      // Standard card output
      const int outputWidth = 700;
      const int outputHeight = 1000;

      // Convert normalized → actual points
      final src = cv.VecPoint2f.fromList([
        cv.Point2f(
          normalizedCorners[0].dx * imageW,
          normalizedCorners[0].dy * imageH,
        ),
        cv.Point2f(
          normalizedCorners[1].dx * imageW,
          normalizedCorners[1].dy * imageH,
        ),
        cv.Point2f(
          normalizedCorners[2].dx * imageW,
          normalizedCorners[2].dy * imageH,
        ),
        cv.Point2f(
          normalizedCorners[3].dx * imageW,
          normalizedCorners[3].dy * imageH,
        ),
      ]);

      final dst = cv.VecPoint2f.fromList([
        cv.Point2f(0, 0),
        cv.Point2f(outputWidth.toDouble(), 0),
        cv.Point2f(outputWidth.toDouble(), outputHeight.toDouble()),
        cv.Point2f(0, outputHeight.toDouble()),
      ]);

      final transform = cv.getPerspectiveTransform2f(src, dst);

      final warped = cv.warpPerspective(mat, transform, (
        outputWidth,
        outputHeight,
      ));

      final (_, encoded) = cv.imencode(".jpg", warped);

      return encoded;
    } catch (e) {
      debugPrint("Perspective Warp Error: $e");
      return null;
    }
  }

  // =============================================================
  // SORT CORNERS
  // TopLeft, TopRight, BottomRight, BottomLeft
  // =============================================================

  List<Offset> _sortCorners(List<Offset> points) {
    if (points.length != 4) {
      return points;
    }

    final List<Offset> sorted = List.from(points);

    // Top-left = smallest sum
    sorted.sort((a, b) => (a.dx + a.dy).compareTo(b.dx + b.dy));

    final topLeft = sorted.first;
    final bottomRight = sorted.last;

    // Remaining two
    final remaining = sorted.sublist(1, 3);

    Offset topRight;
    Offset bottomLeft;

    if (remaining[0].dx > remaining[1].dx) {
      topRight = remaining[0];
      bottomLeft = remaining[1];
    } else {
      topRight = remaining[1];
      bottomLeft = remaining[0];
    }

    return [topLeft, topRight, bottomRight, bottomLeft];
  }

  // =============================================================
  // EMPTY RESULT
  // =============================================================

  Detection _emptyDetection() {
    return Detection(
      left: 0,
      top: 0,
      right: 0,
      bottom: 0,
      score: 0.0,
      corners: null,
    );
  }
}
