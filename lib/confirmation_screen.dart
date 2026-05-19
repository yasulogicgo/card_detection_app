// confirmation_screen.dart
//
// Drop-in replacement for the ConfirmationScreen in your existing code.
// Key changes vs original:
//   1. After first crop, runs CardCornerDetector on the cropped image
//   2. Passes detected corners to ZoomCropEditor (replaces SecondStageCropOverlay)
//   3. ZoomCropEditor shows loupe, auto-snap button, and corner/edge handles
//   4. Final crop uses the outer guide rect the user confirmed

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'card_corner_detector.dart';
import 'zoom_crop_editor.dart';

// Keep this in sync with your existing kApiEndpoint constant.
const String _kApiEndpoint = "http://192.168.1.27:8000/detect-card-box";

class ConfirmationScreen extends StatefulWidget {
  final String imagePath;
  final Rect? detectedRect;
  final Size? streamSize;

  const ConfirmationScreen({
    super.key,
    required this.imagePath,
    this.detectedRect,
    this.streamSize,
  });

  @override
  State<ConfirmationScreen> createState() => _ConfirmationScreenState();
}

class _ConfirmationScreenState extends State<ConfirmationScreen> {
  // ── State flags ──────────────────────────────────────────────────
  bool _isWorking = false; // crop / upload in progress
  bool _isFirstCropDone = false;

  // ── Image paths ───────────────────────────────────────────────────
  String? _croppedPath; // path of the first-crop file
  Size? _croppedPixelSize; // pixel size of _croppedPath

  // ── Corner detection ──────────────────────────────────────────────
  DetectedCardCorners? _detectedCorners;
  int _editorGeneration = 0;

  // ── Guide rects (kept in sync by ZoomCropEditor callbacks) ────────
  Rect? _outerGuideRect; // = final crop boundary
  Rect? _innerGuideRect; // = card content margin

  // ── Original full-photo data ──────────────────────────────────────
  Rect? _detectedRectInPhoto; // ML Kit rect scaled to photo pixels
  Size? _photoPixelSize; // pixel size of the original photo

  static const double _cropPadFactor = 0.14;

  // ─────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _initPhotoData();
  }

  /// Scale the stream-coordinate ML Kit rect to actual photo pixels.
  Future<void> _initPhotoData() async {
    final streamSize = widget.streamSize;
    final detectedRect = widget.detectedRect;
    if (streamSize == null || detectedRect == null) return;

    final photoSize = await _getImagePixelSize(File(widget.imagePath));
    if (!mounted || photoSize.width <= 0) return;

    final sx = photoSize.width / streamSize.width;
    final sy = photoSize.height / streamSize.height;

    setState(() {
      _photoPixelSize = photoSize;
      _detectedRectInPhoto = Rect.fromLTRB(
        (detectedRect.left * sx).clamp(0, photoSize.width),
        (detectedRect.top * sy).clamp(0, photoSize.height),
        (detectedRect.right * sx).clamp(0, photoSize.width),
        (detectedRect.bottom * sy).clamp(0, photoSize.height),
      );
    });
  }

  // ─────────────────────────────────────────────────────────────────
  // STEP 1 — First crop: zoom into the card region with padding
  // ─────────────────────────────────────────────────────────────────
  Future<void> _doFirstCrop() async {
    final detectedRect = _detectedRectInPhoto;
    final photoSize = _photoPixelSize;
    if (_isFirstCropDone || detectedRect == null || photoSize == null) return;

    setState(() => _isWorking = true);

    try {
      // Add padding around the detected box
      final padX = detectedRect.width * _cropPadFactor;
      final padY = detectedRect.height * _cropPadFactor;
      final cropRect = Rect.fromLTRB(
        math.max(0, detectedRect.left - padX),
        math.max(0, detectedRect.top - padY),
        math.min(photoSize.width, detectedRect.right + padX),
        math.min(photoSize.height, detectedRect.bottom + padY),
      );

      // ── Crop the photo ──
      final photoBytes = await File(widget.imagePath).readAsBytes();
      final decoded = img.decodeImage(photoBytes);
      if (decoded == null) return;
      final oriented = img.bakeOrientation(decoded);

      final sx = oriented.width / photoSize.width;
      final sy = oriented.height / photoSize.height;
      final cx = (cropRect.left * sx).round().clamp(0, oriented.width - 1);
      final cy = (cropRect.top * sy).round().clamp(0, oriented.height - 1);
      final cw = ((cropRect.width * sx).round()).clamp(1, oriented.width - cx);
      final ch =
          ((cropRect.height * sy).round()).clamp(1, oriented.height - cy);

      final cropped =
          img.copyCrop(oriented, x: cx, y: cy, width: cw, height: ch);

      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/first_crop_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(path).writeAsBytes(img.encodeJpg(cropped, quality: 95));

      final croppedSize = Size(cw.toDouble(), ch.toDouble());

      // ── Run corner detector on the cropped image ──
      final corners = await _detectCornersOnImage(cropped, croppedSize);

      if (!mounted) return;
      setState(() {
        _croppedPath = path;
        _croppedPixelSize = croppedSize;
        _detectedCorners = corners;
        _isFirstCropDone = true;
        _isWorking = false;
        _editorGeneration++;
      });
    } catch (e) {
      debugPrint('First crop error: $e');
      if (mounted) setState(() => _isWorking = false);
    }
  }

  // ─────────────────────────────────────────────────────────────────
  // STEP 2 — Confirm: final crop using outerGuideRect + upload
  // ─────────────────────────────────────────────────────────────────
  Future<void> _onConfirm() async {
    final croppedPath = _croppedPath;
    final croppedSize = _croppedPixelSize;
    final outerRect = _outerGuideRect;

    if (croppedPath == null || croppedSize == null) {
      // No first crop yet — just upload the original
      await _uploadAndNavigate(File(widget.imagePath));
      return;
    }

    setState(() => _isWorking = true);

    try {
      File finalFile;

      if (outerRect != null) {
        // ── Precision crop using the outer guide rect ──
        final bytes = await File(croppedPath).readAsBytes();
        final decoded = img.decodeImage(bytes);
        if (decoded == null) throw Exception('Failed to decode cropped image');

        final sx = decoded.width / croppedSize.width;
        final sy = decoded.height / croppedSize.height;

        final fx = (outerRect.left * sx).round().clamp(0, decoded.width - 1);
        final fy = (outerRect.top * sy).round().clamp(0, decoded.height - 1);
        final fw =
            (outerRect.width * sx).round().clamp(1, decoded.width - fx);
        final fh =
            (outerRect.height * sy).round().clamp(1, decoded.height - fy);

        final finalCrop =
            img.copyCrop(decoded, x: fx, y: fy, width: fw, height: fh);

        final dir = await getTemporaryDirectory();
        final finalPath =
            '${dir.path}/final_crop_${DateTime.now().millisecondsSinceEpoch}.jpg';
        await File(finalPath)
            .writeAsBytes(img.encodeJpg(finalCrop, quality: 97));
        finalFile = File(finalPath);
      } else {
        finalFile = File(croppedPath);
      }

      await _uploadAndNavigate(finalFile);
    } catch (e) {
      debugPrint('Confirm error: $e');
      if (mounted) {
        setState(() => _isWorking = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<DetectedCardCorners> _detectCornersOnImage(
    img.Image image,
    Size croppedSize,
  ) async {
    final corners = await CardCornerDetector.detect(
      image,
      threshold: 28,
      margin: 6,
    );
    if (corners.isReliable) return corners;
    return DetectedCardCorners.insetFallback(croppedSize, margin: 16);
  }

  Future<void> _reSnapCorners() async {
    final path = _croppedPath;
    final size = _croppedPixelSize;
    if (path == null || size == null) return;

    setState(() => _isWorking = true);
    try {
      final bytes = await File(path).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return;
      final corners = await _detectCornersOnImage(decoded, size);
      if (!mounted) return;
      setState(() {
        _detectedCorners = corners;
        _outerGuideRect = null;
        _innerGuideRect = null;
        _editorGeneration++;
        _isWorking = false;
      });
    } catch (e) {
      debugPrint('Re-snap error: $e');
      if (mounted) setState(() => _isWorking = false);
    }
  }

  Future<void> _uploadAndNavigate(File imageFile) async {
    try {
      final response = await _uploadImage(imageFile);
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ResultScreen(
            imagePath: imageFile.path,
            apiResponse: response,
          ),
        ),
      );
    } catch (e) {
      debugPrint('Upload error: $e');
      if (mounted) {
        setState(() => _isWorking = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Upload failed: $e')));
      }
    }
  }

  Future<Map<String, dynamic>> _uploadImage(File imageFile) async {
    final req =
        http.MultipartRequest('POST', Uri.parse(_kApiEndpoint));
    req.files.add(await http.MultipartFile.fromPath(
      'file',
      imageFile.path,
      contentType: MediaType('image', 'jpeg'),
    ));
    final response = await http.Response.fromStream(await req.send());
    if (response.statusCode == 200) return json.decode(response.body);
    return {'success': false, 'message': 'Server error ${response.statusCode}'};
  }

  // ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(_isFirstCropDone ? 'Align corners' : 'Preview'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Column(
        children: [
          // ── Main image / editor area ────────────────────────────
          Expanded(child: _buildBody()),

          // ── Bottom button bar ───────────────────────────────────
          _buildButtonBar(),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isWorking) {
      return const Center(
          child: CircularProgressIndicator(color: Colors.white));
    }

    // ── Phase 2: first crop done — show ZoomCropEditor ──
    if (_isFirstCropDone &&
        _croppedPath != null &&
        _croppedPixelSize != null &&
        _detectedCorners != null) {
      return ZoomCropEditor(
        key: ValueKey(_editorGeneration),
        imagePath: _croppedPath!,
        imageCoordinateSize: _croppedPixelSize!,
        initialCorners: _detectedCorners!,
        onOuterRectChanged: (r) => setState(() => _outerGuideRect = r),
        onInnerRectChanged: (r) => setState(() => _innerGuideRect = r),
        onAutoSnap: _reSnapCorners,
      );
    }

    // ── Phase 1: original photo with ML Kit detection box overlay ──
    return GestureDetector(
      onTap: _doFirstCrop,
      child: Stack(
      children: [
        Center(
          child: Image.file(
            File(widget.imagePath),
            fit: BoxFit.contain,
          ),
        ),
        if (_detectedRectInPhoto != null && _photoPixelSize != null)
          Positioned.fill(
            child: LayoutBuilder(builder: (context, constraints) {
              return CustomPaint(
                painter: _DetectionBoxPainter(
                  imageSize: _photoPixelSize!,
                  detectedRect: _detectedRectInPhoto!,
                  containerSize: Size(
                    constraints.maxWidth,
                    constraints.maxHeight,
                  ),
                ),
              );
            }),
          ),
        // "Tap to crop" hint
        Positioned(
          bottom: 16,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'Tap  Crop  to zoom in and align corners',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
          ),
        ),
      ],
    ),
    );
  }

  Widget _buildButtonBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      color: Colors.black87,
      child: _isWorking
          ? const Center(child: CircularProgressIndicator())
          : Row(
              children: [
                // Retake
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 50),
                      side:
                          const BorderSide(color: Colors.white, width: 2),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Retake',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 8),

                // Crop / Reset
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isFirstCropDone
                        ? () {
                            setState(() {
                              _outerGuideRect = null;
                              _innerGuideRect = null;
                              _detectedCorners = null;
                              _croppedPath = null;
                              _croppedPixelSize = null;
                              _isFirstCropDone = false;
                            });
                          }
                        : _doFirstCrop,
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(0, 50),
                      backgroundColor: const Color(0xFF4A80F0),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(
                      _isFirstCropDone ? 'Reset' : 'Crop',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(width: 8),

                // Confirm / Check
                Expanded(
                  child: ElevatedButton(
                    onPressed: _onConfirm,
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(0, 50),
                      backgroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(
                      _isFirstCropDone ? 'Confirm' : 'Check',
                      style: const TextStyle(
                          color: Colors.black, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────
  Future<Size> _getImagePixelSize(File file) async {
    final bytes = await file.readAsBytes();
    final decoded = img.decodeImage(bytes);
    final oriented =
        decoded == null ? null : img.bakeOrientation(decoded);
    if (oriented == null) return Size.zero;
    return Size(oriented.width.toDouble(), oriented.height.toDouble());
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _DetectionBoxPainter
// Draws the ML Kit bounding box on the full photo preview (Phase 1).
// ─────────────────────────────────────────────────────────────────────────────
class _DetectionBoxPainter extends CustomPainter {
  final Size imageSize;
  final Rect detectedRect;
  final Size containerSize;

  const _DetectionBoxPainter({
    required this.imageSize,
    required this.detectedRect,
    required this.containerSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Compute the BoxFit.contain display rect
    final scale = math.min(
      containerSize.width / imageSize.width,
      containerSize.height / imageSize.height,
    );
    final displayW = imageSize.width * scale;
    final displayH = imageSize.height * scale;
    final offsetX = (containerSize.width - displayW) / 2;
    final offsetY = (containerSize.height - displayH) / 2;

    final rect = Rect.fromLTRB(
      offsetX + detectedRect.left * scale,
      offsetY + detectedRect.top * scale,
      offsetX + detectedRect.right * scale,
      offsetY + detectedRect.bottom * scale,
    );

    // Dim background
    final fullPath = Path()..addRect(Offset.zero & size);
    final holePath = Path()
      ..addRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(6)));
    canvas.drawPath(
      Path.combine(PathOperation.difference, fullPath, holePath),
      Paint()..color = Colors.black.withValues(alpha: 0.5),
    );

    // Corner brackets
    final p = Paint()
      ..color = Colors.greenAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;
    const cs = 24.0;
    canvas.drawPath(
      Path()
        ..moveTo(rect.left, rect.top + cs)
        ..lineTo(rect.left, rect.top)
        ..lineTo(rect.left + cs, rect.top)
        ..moveTo(rect.right - cs, rect.top)
        ..lineTo(rect.right, rect.top)
        ..lineTo(rect.right, rect.top + cs)
        ..moveTo(rect.right, rect.bottom - cs)
        ..lineTo(rect.right, rect.bottom)
        ..lineTo(rect.right - cs, rect.bottom)
        ..moveTo(rect.left + cs, rect.bottom)
        ..lineTo(rect.left, rect.bottom)
        ..lineTo(rect.left, rect.bottom - cs),
      p,
    );
  }

  @override
  bool shouldRepaint(_DetectionBoxPainter old) => false;
}

// ─────────────────────────────────────────────────────────────────────────────
// ResultScreen + CardResultPreview + PolygonPainter
// (unchanged from your original — kept here for completeness)
// ─────────────────────────────────────────────────────────────────────────────

class ResultScreen extends StatelessWidget {
  final String imagePath;
  final Map<String, dynamic> apiResponse;
  const ResultScreen(
      {super.key, required this.imagePath, required this.apiResponse});

  @override
  Widget build(BuildContext context) {
    final bool success = apiResponse['success'] ?? false;
    final String message = apiResponse['message'] ?? 'Unknown error';
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
          title: Text(success ? 'Card Detected' : 'Detection Failed'),
          backgroundColor: Colors.transparent),
      body: Column(children: [
        Expanded(
            child: Center(
                child: success
                    ? CardResultPreview(
                        imagePath: imagePath,
                        apiData: apiResponse['data'])
                    : Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.error_outline,
                                  size: 80, color: Colors.red),
                              const SizedBox(height: 16),
                              Text(message,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white))
                            ])))),
        Padding(
            padding: const EdgeInsets.all(24),
            child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 50),
                    backgroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12))),
                child: const Text('Back to Camera',
                    style: TextStyle(
                        color: Colors.black, fontWeight: FontWeight.bold)))),
      ]),
    );
  }
}

class CardResultPreview extends StatelessWidget {
  final String imagePath;
  final Map<String, dynamic>? apiData;
  const CardResultPreview(
      {super.key, required this.imagePath, this.apiData});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      return FutureBuilder<Size>(
        future: _getImageSize(File(imagePath)),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const CircularProgressIndicator();
          final imageSize = snapshot.data!;
          final scaleX = constraints.maxWidth / imageSize.width;
          final widgetH =
              constraints.maxWidth * (imageSize.height / imageSize.width);
          final scaleY = widgetH / imageSize.height;
          List<Offset> corners = [];
          if (apiData != null) {
            if (apiData!.containsKey('topleft')) {
              corners = [
                Offset(apiData!['topleft']['x'].toDouble() * scaleX,
                    apiData!['topleft']['y'].toDouble() * scaleY),
                Offset(apiData!['topright']['x'].toDouble() * scaleX,
                    apiData!['topright']['y'].toDouble() * scaleY),
                Offset(apiData!['bottomright']['x'].toDouble() * scaleX,
                    apiData!['bottomright']['y'].toDouble() * scaleY),
                Offset(apiData!['bottomleft']['x'].toDouble() * scaleX,
                    apiData!['bottomleft']['y'].toDouble() * scaleY),
              ];
            } else if (apiData!.containsKey('box')) {
              final box = apiData!['box'];
              final l = box['x'].toDouble() * scaleX;
              final t = box['y'].toDouble() * scaleY;
              final w = box['width'].toDouble() * scaleX;
              final h = box['height'].toDouble() * scaleY;
              corners = [
                Offset(l, t),
                Offset(l + w, t),
                Offset(l + w, t + h),
                Offset(l, t + h)
              ];
            }
          }
          return Stack(children: [
            Image.file(File(imagePath)),
            if (corners.isNotEmpty)
              Positioned.fill(
                  child: CustomPaint(
                      painter: PolygonPainter(points: corners)))
          ]);
        },
      );
    });
  }

  Future<Size> _getImageSize(File file) async {
    final bytes = await file.readAsBytes();
    final decoded = img.decodeImage(bytes);
    final oriented =
        decoded == null ? null : img.bakeOrientation(decoded);
    if (oriented == null) return Size.zero;
    return Size(oriented.width.toDouble(), oriented.height.toDouble());
  }
}

class PolygonPainter extends CustomPainter {
  final List<Offset> points;
  const PolygonPainter({required this.points});

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    if (points.length < 4) return;
    final path = Path()
      ..moveTo(points[0].dx, points[0].dy)
      ..lineTo(points[1].dx, points[1].dy)
      ..lineTo(points[2].dx, points[2].dy)
      ..lineTo(points[3].dx, points[3].dy)
      ..close();
    canvas.drawPath(path, p);
    final dot = Paint()..color = Colors.red;
    for (final pt in points) canvas.drawCircle(pt, 5, dot);
  }

  @override
  bool shouldRepaint(covariant PolygonPainter old) => true;
}
