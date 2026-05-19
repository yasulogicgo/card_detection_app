import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Result of corner detection on a cropped card image.
class DetectedCardCorners {
  final Offset topLeft;
  final Offset topRight;
  final Offset bottomRight;
  final Offset bottomLeft;
  final bool isReliable;

  const DetectedCardCorners({
    required this.topLeft,
    required this.topRight,
    required this.bottomRight,
    required this.bottomLeft,
    this.isReliable = true,
  });

  Rect get boundingRect => Rect.fromLTRB(
        math.min(topLeft.dx, bottomLeft.dx),
        math.min(topLeft.dy, topRight.dy),
        math.max(topRight.dx, bottomRight.dx),
        math.max(bottomLeft.dy, bottomRight.dy),
      );

  DetectedCardCorners inflate(double amount, Size bounds) {
    return DetectedCardCorners(
      topLeft: Offset(
        (topLeft.dx - amount).clamp(0, bounds.width),
        (topLeft.dy - amount).clamp(0, bounds.height),
      ),
      topRight: Offset(
        (topRight.dx + amount).clamp(0, bounds.width),
        (topRight.dy - amount).clamp(0, bounds.height),
      ),
      bottomRight: Offset(
        (bottomRight.dx + amount).clamp(0, bounds.width),
        (bottomRight.dy + amount).clamp(0, bounds.height),
      ),
      bottomLeft: Offset(
        (bottomLeft.dx - amount).clamp(0, bounds.width),
        (bottomLeft.dy + amount).clamp(0, bounds.height),
      ),
      isReliable: isReliable,
    );
  }

  static DetectedCardCorners insetFallback(Size size, {double margin = 14}) {
    return DetectedCardCorners(
      topLeft: Offset(margin, margin),
      topRight: Offset(size.width - margin, margin),
      bottomRight: Offset(size.width - margin, size.height - margin),
      bottomLeft: Offset(margin, size.height - margin),
      isReliable: false,
    );
  }
}

class _ScanParams {
  final Uint8List jpegBytes;
  final int threshold;
  final int margin;

  const _ScanParams(this.jpegBytes, this.threshold, this.margin);
}

/// Sobel edge scan from all four sides — runs in a background isolate.
class CardCornerDetector {
  static Future<DetectedCardCorners> detect(
    img.Image croppedImage, {
    int threshold = 25,
    int margin = 8,
  }) {
    final bytes = Uint8List.fromList(img.encodeJpg(croppedImage, quality: 92));
    return detectFromBytes(bytes, threshold: threshold, margin: margin);
  }

  static Future<DetectedCardCorners> detectFromBytes(
    Uint8List jpegBytes, {
    int threshold = 25,
    int margin = 8,
  }) {
    return compute(
      _detectIsolate,
      _ScanParams(jpegBytes, threshold, margin),
    );
  }

  static DetectedCardCorners _detectIsolate(_ScanParams p) {
    final decoded = img.decodeImage(p.jpegBytes);
    if (decoded == null) {
      return DetectedCardCorners.insetFallback(const Size(1, 1));
    }

    final image = img.bakeOrientation(decoded);
    final threshold = p.threshold;
    final margin = p.margin;
    final w = image.width;
    final h = image.height;

    final gray = List<int>.filled(w * h, 0);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final px = image.getPixel(x, y);
        gray[y * w + x] = ((px.r * 299 + px.g * 587 + px.b * 114) ~/ 1000);
      }
    }

    int g(int x, int y) => gray[y * w + x];

    int edge(int x, int y) {
      if (x < 1 || x >= w - 1 || y < 1 || y >= h - 1) return 0;
      final gx = (g(x + 1, y - 1) + 2 * g(x + 1, y) + g(x + 1, y + 1)) -
          (g(x - 1, y - 1) + 2 * g(x - 1, y) + g(x - 1, y + 1));
      final gy = (g(x - 1, y + 1) + 2 * g(x, y + 1) + g(x + 1, y + 1)) -
          (g(x - 1, y - 1) + 2 * g(x, y - 1) + g(x + 1, y - 1));
      return (gx.abs() + gy.abs()) ~/ 2;
    }

    double scanLeft(int bandStartY, int bandEndY) {
      for (int x = margin; x < w ~/ 2; x++) {
        var maxE = 0;
        for (int y = bandStartY; y <= bandEndY; y++) {
          maxE = math.max(maxE, edge(x, y));
        }
        if (maxE >= threshold) return x.toDouble();
      }
      return margin.toDouble();
    }

    double scanRight(int bandStartY, int bandEndY) {
      for (int x = w - 1 - margin; x > w ~/ 2; x--) {
        var maxE = 0;
        for (int y = bandStartY; y <= bandEndY; y++) {
          maxE = math.max(maxE, edge(x, y));
        }
        if (maxE >= threshold) return x.toDouble();
      }
      return (w - 1 - margin).toDouble();
    }

    double scanTop(int bandStartX, int bandEndX) {
      for (int y = margin; y < h ~/ 2; y++) {
        var maxE = 0;
        for (int x = bandStartX; x <= bandEndX; x++) {
          maxE = math.max(maxE, edge(x, y));
        }
        if (maxE >= threshold) return y.toDouble();
      }
      return margin.toDouble();
    }

    double scanBottom(int bandStartX, int bandEndX) {
      for (int y = h - 1 - margin; y > h ~/ 2; y--) {
        var maxE = 0;
        for (int x = bandStartX; x <= bandEndX; x++) {
          maxE = math.max(maxE, edge(x, y));
        }
        if (maxE >= threshold) return y.toDouble();
      }
      return (h - 1 - margin).toDouble();
    }

    final qW = w ~/ 3;
    final qH = h ~/ 3;

    final tlX = scanLeft(margin, qH);
    final tlY = scanTop(margin, qW);
    final trX = scanRight(margin, qH);
    final trY = scanTop(w - qW, w - 1 - margin);
    final brX = scanRight(h - qH, h - 1 - margin);
    final brY = scanBottom(w - qW, w - 1 - margin);
    final blX = scanLeft(h - qH, h - 1 - margin);
    final blY = scanBottom(margin, qW);

    final width = math.max(trX, brX) - math.min(tlX, blX);
    final height = math.max(blY, brY) - math.min(tlY, trY);
    final isReliable = width > w * 0.28 && height > h * 0.28;

    return DetectedCardCorners(
      topLeft: Offset(tlX, tlY),
      topRight: Offset(trX, trY),
      bottomRight: Offset(brX, brY),
      bottomLeft: Offset(blX, blY),
      isReliable: isReliable,
    );
  }
}
