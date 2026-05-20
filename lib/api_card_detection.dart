import 'package:card_detacstion_app/api_config.dart';
import 'package:flutter/material.dart';

/// Parsed card geometry + match info from `/detect-card-box` API `data` object.
class ApiCardDetection {
  final bool isDetected;
  final bool boxDetected;
  final Rect? outerBox;
  final List<Offset> corners;
  final String? matchedCard;
  final double? similarityScore;
  final double? margin;
  final String? annotatedImageUrl;

  const ApiCardDetection({
    this.isDetected = false,
    this.boxDetected = false,
    this.outerBox,
    this.corners = const [],
    this.matchedCard,
    this.similarityScore,
    this.margin,
    this.annotatedImageUrl,
  });

  bool get hasGeometry =>
      boxDetected && (outerBox != null || corners.length == 4);

  factory ApiCardDetection.fromResponse(Map<String, dynamic> response) {
    if (response['success'] != true) return const ApiCardDetection();
    final data = response['data'];
    if (data is! Map<String, dynamic>) return const ApiCardDetection();
    return ApiCardDetection.fromData(data);
  }

  factory ApiCardDetection.fromData(Map<String, dynamic> data) {
    Rect? outerBox;
    if (data['box'] is Map) {
      final box = data['box'] as Map;
      final x = _toDouble(box['x']);
      final y = _toDouble(box['y']);
      final w = _toDouble(box['width']);
      final h = _toDouble(box['height']);
      if (x != null && y != null && w != null && h != null && w > 0 && h > 0) {
        outerBox = Rect.fromLTWH(x, y, w, h);
      }
    }

    final corners = <Offset>[];
    if (data['topleft'] is Map &&
        data['topright'] is Map &&
        data['bottomright'] is Map &&
        data['bottomleft'] is Map) {
      final tl = data['topleft'] as Map;
      final tr = data['topright'] as Map;
      final br = data['bottomright'] as Map;
      final bl = data['bottomleft'] as Map;
      corners.addAll([
        Offset(_toDouble(tl['x']) ?? 0, _toDouble(tl['y']) ?? 0),
        Offset(_toDouble(tr['x']) ?? 0, _toDouble(tr['y']) ?? 0),
        Offset(_toDouble(br['x']) ?? 0, _toDouble(br['y']) ?? 0),
        Offset(_toDouble(bl['x']) ?? 0, _toDouble(bl['y']) ?? 0),
      ]);
    } else if (outerBox != null) {
      corners.addAll([
        outerBox.topLeft,
        outerBox.topRight,
        outerBox.bottomRight,
        outerBox.bottomLeft,
      ]);
    }

    String? annotatedUrl;
    final rawUrl = data['annotated_image_url']?.toString();
    if (rawUrl != null && rawUrl.isNotEmpty) {
      annotatedUrl = rawUrl.startsWith('http')
          ? rawUrl
          : '$kHfSpaceBaseUrl$rawUrl';
    }

    return ApiCardDetection(
      isDetected: data['is_detected'] == true,
      boxDetected: data['box_detected'] == true,
      outerBox: outerBox,
      corners: corners,
      matchedCard: data['matched_card']?.toString(),
      similarityScore: _toDouble(data['similarity_score']),
      margin: _toDouble(data['margin']),
      annotatedImageUrl: annotatedUrl,
    );
  }

  static double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }
}
