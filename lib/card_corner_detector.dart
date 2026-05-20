import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:opencv_dart/opencv.dart' as cv;

/// Result of OpenCV card corner / bounding-box detection in image pixel space.
class CardCornerDetectionResult {
  final bool success;
  final List<Offset> corners;
  final Rect outerBoundingBox;
  final String? errorMessage;

  const CardCornerDetectionResult({
    required this.success,
    this.corners = const [],
    this.outerBoundingBox = Rect.zero,
    this.errorMessage,
  });
}

/// Detects a playing-card-like quadrilateral using OpenCV contours.
class CardCornerDetector {
  static const double _targetAspect = 0.714; // ~2.5:3.5 portrait card
  static const double _minAreaFraction = 0.08;
  static const double _maxAreaFraction = 0.55;

  /// Runs contour-based card detection on [imageFile].
  static Future<CardCornerDetectionResult> detectFromFile(
    File imageFile, {
    Rect? searchRegion,
    double outerPadding = 8.0,
  }) async {
    cv.Mat? mat;
    try {
      mat = await _loadOrientedMat(imageFile);
      if (mat.isEmpty) {
        return const CardCornerDetectionResult(
          success: false,
          errorMessage: 'Could not load image',
        );
      }

      var result = detectFromMat(
        mat,
        searchRegion: searchRegion,
        outerPadding: outerPadding,
      );

      // Retry on full image if ML-hint region excluded the real card.
      if (!result.success && searchRegion != null) {
        result = detectFromMat(
          mat,
          searchRegion: null,
          outerPadding: outerPadding,
        );
      }

      return result;
    } catch (e) {
      return CardCornerDetectionResult(
        success: false,
        errorMessage: e.toString(),
      );
    } finally {
      mat?.dispose();
    }
  }

  /// Loads pixels with EXIF orientation applied so coordinates match Flutter UI.
  static Future<cv.Mat> _loadOrientedMat(File imageFile) async {
    final bytes = await imageFile.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return cv.imread(imageFile.path, flags: cv.IMREAD_COLOR);
    }
    final baked = img.bakeOrientation(decoded);
    final encoded = Uint8List.fromList(img.encodeJpg(baked, quality: 95));
    return cv.imdecode(encoded, cv.IMREAD_COLOR);
  }

  static CardCornerDetectionResult detectFromMat(
    cv.Mat source, {
    Rect? searchRegion,
    double outerPadding = 8.0,
  }) {
    final imageWidth = source.cols.toDouble();
    final imageHeight = source.rows.toDouble();
    if (imageWidth <= 0 || imageHeight <= 0) {
      return const CardCornerDetectionResult(
        success: false,
        errorMessage: 'Invalid image dimensions',
      );
    }

    final maxDim = math.max(imageWidth, imageHeight);
    final scale = maxDim > 1400 ? 1400 / maxDim : 1.0;

    cv.Mat? scaled;
    cv.Mat? gray;
    cv.Mat? blurred;

    try {
      final working = scale < 1.0
          ? (scaled = cv.resize(
              source,
              (0, 0),
              fx: scale,
              fy: scale,
              interpolation: cv.INTER_AREA,
            ))
          : source;

      gray = cv.cvtColor(working, cv.COLOR_BGR2GRAY);
      blurred = cv.gaussianBlur(gray, (5, 5), 0);

      final scaledSearch = _scaledSearchRegion(
        searchRegion,
        scale,
        working.cols.toDouble(),
        working.rows.toDouble(),
      );

      _CardCandidate? best;

      for (final binary in _buildBinaryImages(blurred)) {
        best = _pickBestCandidate(
          binary,
          imageArea: working.cols * working.rows,
          scaledSearch: scaledSearch,
          currentBest: best,
        );
        binary.dispose();
        if (best != null && best.score > 0.85) break;
      }

      if (best == null) {
        return const CardCornerDetectionResult(
          success: false,
          errorMessage: 'No card contour found',
        );
      }

      final invScale = 1.0 / scale;
      final corners = best.corners
          .map((p) => Offset(p.dx * invScale, p.dy * invScale))
          .toList();

      var minX = corners.first.dx;
      var maxX = corners.first.dx;
      var minY = corners.first.dy;
      var maxY = corners.first.dy;
      for (final c in corners) {
        minX = math.min(minX, c.dx);
        maxX = math.max(maxX, c.dx);
        minY = math.min(minY, c.dy);
        maxY = math.max(maxY, c.dy);
      }

      final outer = Rect.fromLTRB(
        (minX - outerPadding).clamp(0.0, imageWidth),
        (minY - outerPadding).clamp(0.0, imageHeight),
        (maxX + outerPadding).clamp(0.0, imageWidth),
        (maxY + outerPadding).clamp(0.0, imageHeight),
      );

      return CardCornerDetectionResult(
        success: true,
        corners: corners,
        outerBoundingBox: outer,
      );
    } catch (e) {
      return CardCornerDetectionResult(
        success: false,
        errorMessage: e.toString(),
      );
    } finally {
      scaled?.dispose();
      gray?.dispose();
      blurred?.dispose();
    }
  }

  static List<cv.Mat> _buildBinaryImages(cv.Mat blurred) {
    final images = <cv.Mat>[];

    // Strategy 1: adaptive threshold (works well for cards on table)
    images.add(
      cv.adaptiveThreshold(
        blurred,
        255,
        cv.ADAPTIVE_THRESH_GAUSSIAN_C,
        cv.THRESH_BINARY,
        11,
        2,
      ),
    );

    // Strategy 2: inverted adaptive (dark card on light bg)
    images.add(
      cv.adaptiveThreshold(
        blurred,
        255,
        cv.ADAPTIVE_THRESH_GAUSSIAN_C,
        cv.THRESH_BINARY_INV,
        11,
        2,
      ),
    );

    // Strategy 3: Canny + dilate
    final edges = cv.canny(blurred, 80, 200);
    final kernel = cv.getStructuringElement(cv.MORPH_RECT, (3, 3));
    final dilated = cv.dilate(edges, kernel, iterations: 2);
    edges.dispose();
    kernel.dispose();
    images.add(dilated);

    // Strategy 4: Otsu
    final otsu = cv.threshold(blurred, 0, 255, cv.THRESH_BINARY | cv.THRESH_OTSU).$2;
    images.add(otsu);

    return images;
  }

  static _CardCandidate? _pickBestCandidate(
    cv.Mat binary, {
    required int imageArea,
    required Rect? scaledSearch,
    required _CardCandidate? currentBest,
  }) {
    cv.Mat? closed;
    try {
      final kernel = cv.getStructuringElement(cv.MORPH_RECT, (3, 3));
      closed = cv.morphologyEx(binary, cv.MORPH_CLOSE, kernel);
      kernel.dispose();

      final (contours, _) = cv.findContours(
        closed,
        cv.RETR_EXTERNAL,
        cv.CHAIN_APPROX_SIMPLE,
      );

      _CardCandidate? best = currentBest;

      for (var i = 0; i < contours.length; i++) {
        final contour = contours[i];
        final area = cv.contourArea(contour);
        if (area < imageArea * _minAreaFraction) continue;
        if (area > imageArea * _maxAreaFraction) continue;

        final corners = _extractCorners(contour);
        if (corners == null) continue;

        final score = _scoreCandidate(
          corners: corners,
          area: area,
          imageArea: imageArea,
          scaledSearch: scaledSearch,
        );
        if (score <= 0) continue;

        if (best == null || score > best.score) {
          best = _CardCandidate(corners: corners, area: area, score: score);
        }
      }

      return best;
    } finally {
      closed?.dispose();
    }
  }

  static List<Offset>? _extractCorners(cv.VecPoint contour) {
    final peri = cv.arcLength(contour, true);
    for (final epsFactor in [0.02, 0.03, 0.04, 0.06, 0.08, 0.1]) {
      final approx = cv.approxPolyDP(contour, epsFactor * peri, true);
      if (approx.length == 4 && cv.isContourConvex(approx)) {
        return _orderCornerPoints(approx);
      }
    }

    // Fallback: minimum-area rotated rectangle
    final rot = cv.minAreaRect(contour);
    final pts = cv.boxPoints(rot);
    if (pts.length == 4) {
      return _orderCornerPoints2f(pts);
    }
    return null;
  }

  static double _scoreCandidate({
    required List<Offset> corners,
    required double area,
    required int imageArea,
    required Rect? scaledSearch,
  }) {
    final bounds = _boundsFromCorners(corners);

    final w = bounds.width;
    final h = bounds.height;

    if (w < 80 || h < 120) return 0;

    // portrait card ratio
    final ratio = w < h ? w / h : h / w;

    // strict ratio check
    if (ratio < 0.55 || ratio > 0.80) {
      return 0;
    }

    final areaRatio = area / imageArea;
    final center = Offset(
      bounds.center.dx,
      bounds.center.dy,
    );

    final imageCenter = Offset(
      math.max(bounds.right, bounds.left),
      math.max(bounds.bottom, bounds.top),
    );

    final dx = center.dx - imageCenter.dx / 2;
    final dy = center.dy - imageCenter.dy / 2;

    final distance =
    math.sqrt(dx * dx + dy * dy);

    if (distance > 500) {
      return 0;
    }

    // reject giant contour
    if (areaRatio > 0.60) return 0;

    // reject tiny contour
    if (areaRatio < 0.08) return 0;

    // angle check
    final tl = corners[0];
    final tr = corners[1];
    final br = corners[2];
    final bl = corners[3];

    final topWidth = (tr - tl).distance;
    final bottomWidth = (br - bl).distance;

    final leftHeight = (bl - tl).distance;
    final rightHeight = (br - tr).distance;

    final widthBalance =
        math.min(topWidth, bottomWidth) /
            math.max(topWidth, bottomWidth);

    final heightBalance =
        math.min(leftHeight, rightHeight) /
            math.max(leftHeight, rightHeight);

    if (widthBalance < 0.6) return 0;
    if (heightBalance < 0.6) return 0;

    double regionScore = 1.0;

    if (scaledSearch != null) {
      final center = Offset(
        corners.map((e) => e.dx).reduce((a, b) => a + b) / 4,
        corners.map((e) => e.dy).reduce((a, b) => a + b) / 4,
      );

      // HARD reject outside region
      if (!scaledSearch.contains(center)) {
        return 0;
      }

      regionScore = 1.5;
    }

    final aspectScore =
        1.0 - ((ratio - _targetAspect).abs() / _targetAspect);

    return
      (aspectScore * 0.45) +
          (areaRatio * 0.30) +
          (widthBalance * 0.10) +
          (heightBalance * 0.10) +
          (regionScore * 0.05);
  }

  static Rect? _scaledSearchRegion(
    Rect? region,
    double scale,
    double maxW,
    double maxH,
  ) {
    if (region == null) return null;
    final expanded = region.inflate(
      math.max(region.width, region.height) * 0.35,
    );
    return Rect.fromLTRB(
      (expanded.left * scale).clamp(0.0, maxW),
      (expanded.top * scale).clamp(0.0, maxH),
      (expanded.right * scale).clamp(0.0, maxW),
      (expanded.bottom * scale).clamp(0.0, maxH),
    );
  }

  static Rect _boundsFromCorners(List<Offset> corners) {
    var minX = corners.first.dx;
    var maxX = corners.first.dx;
    var minY = corners.first.dy;
    var maxY = corners.first.dy;
    for (final c in corners) {
      minX = math.min(minX, c.dx);
      maxX = math.max(maxX, c.dx);
      minY = math.min(minY, c.dy);
      maxY = math.max(maxY, c.dy);
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  static List<Offset> _orderCornerPoints(cv.VecPoint pts) {
    final points = <Offset>[
      for (var i = 0; i < pts.length; i++)
        Offset(pts[i].x.toDouble(), pts[i].y.toDouble()),
    ];
    return _orderCornerOffsets(points);
  }

  static List<Offset> _orderCornerPoints2f(cv.VecPoint2f pts) {
    final points = <Offset>[
      for (var i = 0; i < pts.length; i++)
        Offset(pts[i].x, pts[i].y),
    ];
    return _orderCornerOffsets(points);
  }

  static List<Offset> _orderCornerOffsets(List<Offset> points) {
    points.sort((a, b) => a.dy.compareTo(b.dy));
    final top = points.sublist(0, 2)..sort((a, b) => a.dx.compareTo(b.dx));
    final bottom = points.sublist(2, 4)..sort((a, b) => a.dx.compareTo(b.dx));
    return [top[0], top[1], bottom[1], bottom[0]];
  }
}

class _CardCandidate {
  final List<Offset> corners;
  final double area;
  final double score;

  const _CardCandidate({
    required this.corners,
    required this.area,
    required this.score,
  });
}
