import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:card_detacstion_app/api_card_detection.dart';
import 'package:card_detacstion_app/api_config.dart';
import 'package:card_detacstion_app/card_corner_detector.dart';
import 'package:sensors_plus/sensors_plus.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// CARD SCANNER SCREEN
// ═══════════════════════════════════════════════════════════════════════════════

class CardScannerScreen extends StatefulWidget {
  const CardScannerScreen({super.key});

  @override
  State<CardScannerScreen> createState() => _CardScannerScreenState();
}

class _CardScannerScreenState extends State<CardScannerScreen> {
  CameraController? _cameraController;
  late ObjectDetector _objectDetector;
  bool _isProcessing = false;
  bool _isCapturing = false;
  bool _isResumingStream = false;
  int? _lastProcessTime;

  DetectedObject? _detectedObject;
  Size? _imageSize;
  InputImageRotation? _rotation;

  // ── Sensor / level ──────────────────────────────────────────────
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;
  double _rollDeg = 0;
  double _pitchDeg = 0;
  double _flatTiltDeg = 0;

  /// Degrees from center where bubble is "in the middle" (can capture).
  static const double _centerZoneDeg = 4.0;

  /// At this tilt (per axis / flatness) color is fully red.
  static const double _levelRedAtDeg = 16.0;

  /// Capture only in the green zone (0 = perfect … 1 = red).
  static const double _captureMaxScore = 0.22;

  bool _isRollCentered = false;
  bool _isPitchCentered = false;
  bool _showSpiritLevel = true;

  double get _rollScore => (_rollDeg.abs() / _levelRedAtDeg).clamp(0.0, 1.0);

  double get _pitchScore => (_pitchDeg.abs() / _levelRedAtDeg).clamp(0.0, 1.0);

  double get _flatScore => (_flatTiltDeg / _levelRedAtDeg).clamp(0.0, 1.0);

  /// Worst-axis alignment (drives frame color + capture gate).
  double get _levelScore =>
      math.max(_rollScore, math.max(_pitchScore, _flatScore));

  bool get _isBubbleCentered => _isRollCentered && _isPitchCentered;

  bool get _isDeviceLevel =>
      _isBubbleCentered && _levelScore <= _captureMaxScore;

  bool get _canCapture => _detectedObject != null && _isDeviceLevel;

  @override
  void initState() {
    super.initState();
    _initialize();
    _startSensorTracking();
  }

  void _startSensorTracking() {
    _accelerometerSubscription = accelerometerEvents.listen((event) {
      if (!mounted) return;

      final x = event.x;
      final y = event.y;
      final z = event.z;

      // Z-axis tilt: 0° = perfectly flat, 90° = vertical
      final magnitude = math.sqrt(x * x + y * y + z * z);
      final tilt = magnitude > 0
          ? math.acos((z / magnitude).clamp(-1.0, 1.0)) * (180 / math.pi)
          : 0.0;

      // FIX #2: roll/pitch calculated correctly for portrait-up orientation.
      // On Android, X goes right, Y goes up, Z goes toward user.
      // Roll = left-right tilt, Pitch = forward-back tilt.
      final roll = math.atan2(x, z) * (180 / math.pi);
      final pitch = math.atan2(y, z) * (180 / math.pi);

      setState(() {
        _rollDeg = -roll;
        _pitchDeg = pitch;
        _flatTiltDeg = tilt;
        _isRollCentered = roll.abs() <= _centerZoneDeg;
        _isPitchCentered = pitch.abs() <= _centerZoneDeg;
      });
    });
  }

  Future<void> _initialize() async {
    final cameras = await availableCameras();
    final backCamera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
    );

    _cameraController = CameraController(
      backCamera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );

    await _cameraController!.initialize();
    await _cameraController!.setFlashMode(FlashMode.off);
    await _cameraController!.lockCaptureOrientation(
      DeviceOrientation.portraitUp,
    );

    _objectDetector = ObjectDetector(
      options: ObjectDetectorOptions(
        mode: DetectionMode.stream,
        classifyObjects: false,
        multipleObjects: false,
      ),
    );

    await _cameraController!.startImageStream(_processCameraImage);
    if (mounted) setState(() {});
  }

  Future<void> _processCameraImage(CameraImage image) async {
    // FIX #4: Run ML Kit EVEN when not perfectly level.
    // We still show the detection box while tilted — only the capture button
    // is disabled when not level. This way the user sees feedback at all times.
    if (_isProcessing || _isCapturing) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastProcessTime != null && now - _lastProcessTime! < 200) return;
    _lastProcessTime = now;

    _isProcessing = true;
    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) {
        _isProcessing = false;
        return;
      }

      final objects = await _objectDetector.processImage(inputImage);

      // FIX #5: When multiple objects detected, pick the LARGEST one that
      // passes the card check — not just objects.first which could be wrong card.
      DetectedObject? bestCard;
      final imageSize = Size(image.width.toDouble(), image.height.toDouble());
      for (final obj in objects) {
        if (_isCard(obj.boundingBox, imageSize)) {
          if (bestCard == null ||
              obj.boundingBox.width * obj.boundingBox.height >
                  bestCard.boundingBox.width * bestCard.boundingBox.height) {
            bestCard = obj;
          }
        }
      }

      if (mounted) {
        setState(() {
          _detectedObject = bestCard;
          final rot =
              inputImage.metadata?.rotation ?? InputImageRotation.rotation0deg;
          final sz = inputImage.metadata?.size ?? Size.zero;
          _imageSize =
              (rot == InputImageRotation.rotation90deg ||
                  rot == InputImageRotation.rotation270deg)
              ? Size(sz.height, sz.width)
              : sz;
          _rotation = rot;
        });
      }
    } catch (e) {
      debugPrint(e.toString());
    }
    _isProcessing = false;
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    final camera = _cameraController?.description;
    if (camera == null) return null;
    final imageRotation =
        InputImageRotationValue.fromRawValue(camera.sensorOrientation) ??
        InputImageRotation.rotation0deg;
    final inputImageFormat =
        InputImageFormatValue.fromRawValue(image.format.raw) ??
        InputImageFormat.nv21;
    return InputImage.fromBytes(
      bytes: image.planes.first.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: imageRotation,
        format: inputImageFormat,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  bool _isCard(Rect rect, Size imageSize) {
    final w = rect.width;
    final h = rect.height;

    // Vertical orientation (portrait card)
    if (w > h) return false;

    // FIX #6: Wider aspect ratio range to handle slight perspective distortion.
    // Standard card is 0.714 but in-hand or slight angle changes it.
    final ratio = w / h;
    if (ratio < 0.55 || ratio > 0.88) return false;

    // Minimum size — card must be reasonably large in frame
    if (w < 100 || h < 150) return false;

    // FIX #7: More generous center tolerance (was 200px, now 240px).
    // Cards near the edge of frame are still valid — user guides the card in.
    final dx = (rect.center.dx - imageSize.width / 2).abs();
    final dy = (rect.center.dy - imageSize.height / 2).abs();
    if (dx > 240 || dy > 240) return false;

    return true;
  }

  Future<void> _stopImageStreamSafely() async {
    final c = _cameraController;
    if (c == null || !c.value.isInitialized) return;
    if (!c.value.isStreamingImages) return;
    try {
      await c.stopImageStream();
      await Future<void>.delayed(const Duration(milliseconds: 250));
    } catch (e) {
      debugPrint('Stop stream: $e');
    }
  }

  Future<void> _captureImage() async {
    if (_detectedObject == null || _imageSize == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No card detected — frame the card first'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    if (!_isBubbleCentered) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Center the level bubble between the lines to capture'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    if (!_isDeviceLevel) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _levelScore > 0.55
                ? 'Hold the phone flatter — level is red'
                : 'Align bubble to center (green) to capture',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    if (_isCapturing ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized)
      return;

    final currentRect = _detectedObject!.boundingBox;
    final currentStreamSize = _imageSize!;

    setState(() {
      _isCapturing = true;
      _detectedObject = null;
    });

    try {
      await _stopImageStreamSafely();
      if (!mounted ||
          _cameraController == null ||
          !_cameraController!.value.isInitialized)
        return;

      final XFile file = await _cameraController!.takePicture();
      if (!mounted) return;

      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ConfirmationScreen(
            imagePath: file.path,
            detectedRect: currentRect,
            streamSize: currentStreamSize,
          ),
        ),
      );
      if (mounted) await _resumeStream();
    } catch (e) {
      debugPrint('Capture error: $e');
      if (mounted) await _resumeStream();
    }
  }

  Future<void> _resumeStream() async {
    if (!mounted || _isResumingStream) return;
    final c = _cameraController;
    if (c == null || !c.value.isInitialized) {
      if (mounted)
        setState(() {
          _isCapturing = false;
          _detectedObject = null;
        });
      return;
    }
    if (c.value.isStreamingImages) {
      if (mounted)
        setState(() {
          _isCapturing = false;
        });
      return;
    }
    _isResumingStream = true;
    try {
      if (mounted)
        setState(() {
          _isCapturing = false;
          _detectedObject = null;
        });
      await c.setFlashMode(FlashMode.off);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!mounted || !c.value.isInitialized) return;
      await c.startImageStream(_processCameraImage);
    } catch (e) {
      debugPrint('Resume stream: $e');
      await _reinitializeCamera();
    } finally {
      _isResumingStream = false;
    }
  }

  Future<void> _reinitializeCamera() async {
    final old = _cameraController;
    _cameraController = null;
    try {
      if (old != null) {
        if (old.value.isStreamingImages) await old.stopImageStream();
        await old.dispose();
      }
    } catch (e) {
      debugPrint('Dispose: $e');
    }
    if (!mounted) return;
    try {
      final cameras = await availableCameras();
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
      );
      _cameraController = CameraController(
        back,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );
      await _cameraController!.initialize();
      await _cameraController!.setFlashMode(FlashMode.off);
      await _cameraController!.lockCaptureOrientation(
        DeviceOrientation.portraitUp,
      );
      await _cameraController!.startImageStream(_processCameraImage);
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Reinit: $e');
    }
  }

  @override
  void dispose() {
    _accelerometerSubscription?.cancel();
    final c = _cameraController;
    if (c != null) {
      if (c.value.isStreamingImages) c.stopImageStream().catchError((_) {});
      c.dispose();
    }
    _objectDetector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final previewAR = 1 / _cameraController!.value.aspectRatio;
    final canCapture = _canCapture;
    final frameColor = _levelColorFromScore(_levelScore);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Camera preview
          Center(
            child: AspectRatio(
              aspectRatio: previewAR,
              child: CameraPreview(_cameraController!),
            ),
          ),

          // ML Kit detection box — shown even when tilted
          if (_detectedObject != null &&
              _imageSize != null &&
              _rotation != null)
            IgnorePointer(
              child: Center(
                child: AspectRatio(
                  aspectRatio: previewAR,
                  child: CustomPaint(
                    painter: ObjectDetectorPainter(
                      [_detectedObject!],
                      _imageSize!,
                      _rotation!,
                      _cameraController!.description.lensDirection,
                      levelColor: _detectedObject != null
                          ? frameColor
                          : Colors.white38,
                    ),
                  ),
                ),
              ),
            ),

          // Card placement guide frame
          if (!_isCapturing && _detectedObject != null)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: CardGuideOverlayPainter(levelColor: Colors.transparent),
                ),
              ),
            ),

          // Spirit level bars
          if (!_isCapturing && _showSpiritLevel) ...[
            Positioned(
              top: MediaQuery.of(context).padding.top + 72,
              left: 0,
              right: 0,
              child: Center(
                child: SpiritLevelBar(
                  axis: SpiritLevelAxis.horizontal,
                  tiltDegrees: _rollDeg,
                  levelScore: _rollScore,
                  isCentered: _isRollCentered,
                ),
              ),
            ),
            Positioned(
              left: 10,
              top: 0,
              bottom: 0,
              child: Center(
                child: SpiritLevelBar(
                  axis: SpiritLevelAxis.vertical,
                  tiltDegrees: _pitchDeg,
                  levelScore: _pitchScore,
                  isCentered: _isPitchCentered,
                ),
              ),
            ),
          ],

          // FIX #11: Status chip shows DIFFERENT messages based on what's wrong.
          if (!_isCapturing)
            Positioned(
              top: MediaQuery.of(context).padding.top + 16,
              left: 0,
              right: 0,
              child: Center(child: _buildStatusChip()),
            ),

          // Bottom controls
          Positioned(
            bottom: 36,
            left: 20,
            right: 20,
            child: Row(
              children: [
                const Spacer(flex: 2),
                _isCapturing
                    ? const CircularProgressIndicator(color: Colors.white)
                    : FloatingActionButton(
                        onPressed: _captureImage,
                        backgroundColor: canCapture
                            ? Colors.white
                            : Colors.grey.shade700,
                        child: Icon(
                          Icons.camera_alt,
                          color: canCapture ? Colors.black : Colors.white38,
                          size: 28,
                        ),
                      ),
                const Spacer(),
                Material(
                  color: Colors.black.withOpacity(0.45),
                  shape: const CircleBorder(),
                  child: IconButton(
                    onPressed: () =>
                        setState(() => _showSpiritLevel = !_showSpiritLevel),
                    icon: Icon(
                      Icons.straighten,
                      color: _showSpiritLevel ? Colors.white : Colors.white38,
                    ),
                    tooltip: 'Toggle level guides',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Green (perfect) → yellow (drifting) → red (too far off).
  static Color _levelColorFromScore(double score) {
    const green = Color(0xFF32FF32);
    const yellow = Color(0xFFFFEB3B);
    const red = Color(0xFFFF5252);
    final s = score.clamp(0.0, 1.0);
    if (s <= 0.5) {
      return Color.lerp(green, yellow, s * 2)!;
    }
    return Color.lerp(yellow, red, (s - 0.5) * 2)!;
  }

  Widget _buildStatusChip() {
    if (_isCapturing) return const SizedBox.shrink();

    String text;
    Color bg;
    IconData icon;

    if (_detectedObject != null && _canCapture) {
      text = 'CARD READY — TAP CAPTURE';
      bg = Colors.green.withValues(alpha: 0.85);
      icon = Icons.check_circle_outline;
    } else if (_detectedObject != null && !_isBubbleCentered) {
      text = 'CENTER LEVEL BUBBLE';
      bg = _levelColorFromScore(_levelScore).withValues(alpha: 0.9);
      icon = Icons.adjust;
    } else if (_detectedObject != null && _levelScore > 0.5) {
      text = 'HOLD PHONE FLATTER';
      bg = Colors.red.withValues(alpha: 0.85);
      icon = Icons.warning_amber_rounded;
    } else if (_detectedObject != null) {
      text = 'ALIGN TO GREEN';
      bg = _levelColorFromScore(_levelScore).withValues(alpha: 0.9);
      icon = Icons.tune;
    } else if (_isBubbleCentered) {
      text = 'ALIGN CARD IN FRAME';
      bg = Colors.black.withValues(alpha: 0.55);
      icon = Icons.crop_free;
    } else {
      text = 'CENTER LEVEL BUBBLE';
      bg = _levelColorFromScore(_levelScore).withValues(alpha: 0.75);
      icon = Icons.adjust;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 14),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 12,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// SPIRIT LEVEL WIDGETS
// ═══════════════════════════════════════════════════════════════════════════════

enum SpiritLevelAxis { horizontal, vertical }

class SpiritLevelBar extends StatelessWidget {
  final SpiritLevelAxis axis;
  final double tiltDegrees;
  final double levelScore;
  final bool isCentered;

  const SpiritLevelBar({
    super.key,
    required this.axis,
    required this.tiltDegrees,
    required this.levelScore,
    required this.isCentered,
  });

  @override
  Widget build(BuildContext context) {
    final isH = axis == SpiritLevelAxis.horizontal;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: isH ? 300 : 20,
      height: isH ? 20 : 260,
      child: CustomPaint(
        painter: SpiritLevelBarPainter(
          isHorizontal: isH,
          normalizedOffset:
              (tiltDegrees / _CardScannerScreenState._levelRedAtDeg).clamp(
                -1.0,
                1.0,
              ),
          levelScore: levelScore,
          isCentered: isCentered,
        ),
      ),
    );
  }
}

class SpiritLevelBarPainter extends CustomPainter {
  final bool isHorizontal;
  final double normalizedOffset;
  final double levelScore;
  final bool isCentered;

  const SpiritLevelBarPainter({
    required this.isHorizontal,
    required this.normalizedOffset,
    required this.levelScore,
    required this.isCentered,
  });

  static Color _colorFromScore(double score) {
    const green = Color(0xFF32FF32);
    const yellow = Color(0xFFFFEB3B);
    const red = Color(0xFFFF5252);
    final s = score.clamp(0.0, 1.0);
    if (s <= 0.5) return Color.lerp(green, yellow, s * 2)!;
    return Color.lerp(yellow, red, (s - 0.5) * 2)!;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final accent = _colorFromScore(levelScore);
    final barTint = Color.lerp(
      const Color(0x8838FF72),
      accent.withValues(alpha: 0.55),
      levelScore,
    )!;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Offset.zero & size,
        Radius.circular(size.shortestSide),
      ),
      Paint()
        ..shader = LinearGradient(
          colors: [barTint, barTint.withValues(alpha: 0.35)],
        ).createShader(Offset.zero & size),
    );

    final markerPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2;
    if (isHorizontal) {
      canvas.drawLine(
        Offset(size.width / 2 - 26, 0),
        Offset(size.width / 2 - 26, size.height),
        markerPaint,
      );
      canvas.drawLine(
        Offset(size.width / 2 + 26, 0),
        Offset(size.width / 2 + 26, size.height),
        markerPaint,
      );
    } else {
      canvas.drawLine(
        Offset(0, size.height / 2 - 26),
        Offset(size.width, size.height / 2 - 26),
        markerPaint,
      );
      canvas.drawLine(
        Offset(0, size.height / 2 + 26),
        Offset(size.width, size.height / 2 + 26),
        markerPaint,
      );
    }

    final t = ((normalizedOffset + 1) / 2).clamp(0.0, 1.0);
    final bubbleCenter = isHorizontal
        ? Offset(t * size.width, size.height / 2)
        : Offset(size.width / 2, t * size.height);

    if (isCentered) {
      canvas.drawCircle(
        bubbleCenter,
        18,
        Paint()
          ..color = accent.withValues(alpha: 0.25)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    canvas.drawCircle(
      bubbleCenter,
      14,
      Paint()
        ..color = accent.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );

    canvas.drawCircle(
      bubbleCenter,
      12,
      Paint()
        ..shader = RadialGradient(
          colors: [Colors.white, accent],
        ).createShader(Rect.fromCircle(center: bubbleCenter, radius: 12)),
    );

    canvas.drawCircle(
      bubbleCenter.translate(-3, -3),
      3,
      Paint()..color = Colors.white.withValues(alpha: 0.9),
    );
  }

  @override
  bool shouldRepaint(SpiritLevelBarPainter old) =>
      old.normalizedOffset != normalizedOffset ||
      old.levelScore != levelScore ||
      old.isCentered != isCentered;
}

// ═══════════════════════════════════════════════════════════════════════════════
// CARD GUIDE OVERLAY PAINTER
// FIX #14: Guide frame color reacts to card detection, not just level.
// ═══════════════════════════════════════════════════════════════════════════════

class CardGuideOverlayPainter extends CustomPainter {
  final Color levelColor;

  const CardGuideOverlayPainter({required this.levelColor});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final cardH = size.height * 0.56;
    final cardW = cardH * 0.72;
    final cardRect = Rect.fromCenter(
      center: center,
      width: cardW,
      height: cardH,
    );

    final activeColor = levelColor;

    // Dim outside
    final dimPath = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(RRect.fromRectAndRadius(cardRect, const Radius.circular(10)))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(dimPath, Paint()..color = Colors.transparent);

    // Guide border
    canvas.drawRRect(
      RRect.fromRectAndRadius(cardRect, const Radius.circular(10)),
      Paint()
        ..color = activeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    _drawCornerBrackets(canvas, cardRect, activeColor);
  }

  void _drawCornerBrackets(Canvas canvas, Rect rect, Color color) {
    const len = 20.0;
    final p = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(len, 0), p);
    canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(0, len), p);
    canvas.drawLine(rect.topRight, rect.topRight + const Offset(-len, 0), p);
    canvas.drawLine(rect.topRight, rect.topRight + const Offset(0, len), p);
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft + const Offset(len, 0), p);
    canvas.drawLine(
      rect.bottomLeft,
      rect.bottomLeft + const Offset(0, -len),
      p,
    );
    canvas.drawLine(
      rect.bottomRight,
      rect.bottomRight + const Offset(-len, 0),
      p,
    );
    canvas.drawLine(
      rect.bottomRight,
      rect.bottomRight + const Offset(0, -len),
      p,
    );
  }

  @override
  bool shouldRepaint(CardGuideOverlayPainter old) =>
      old.levelColor != levelColor;
}

// ═══════════════════════════════════════════════════════════════════════════════
// ML KIT DETECTION BOX PAINTER
// FIX #15: Box is green when level, orange when card found but tilted
// ═══════════════════════════════════════════════════════════════════════════════

class ObjectDetectorPainter extends CustomPainter {
  final List<DetectedObject> objects;
  final Size imageSize;
  final InputImageRotation rotation;
  final CameraLensDirection lensDirection;
  final Color levelColor;

  ObjectDetectorPainter(
    this.objects,
    this.imageSize,
    this.rotation,
    this.lensDirection, {
    this.levelColor = Colors.greenAccent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final boxColor = levelColor;
    final paintCorners = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.0
      ..color = boxColor
      ..strokeCap = StrokeCap.round;
    final paintFill = Paint()
      ..style = PaintingStyle.fill
      ..color = boxColor.withAlpha(70);

    for (final object in objects) {
      final rect = _translateRect(object.boundingBox, imageSize, size);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(8)),
        paintFill,
      );

      const cs = 25.0;
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
        paintCorners,
      );

      final dot = Paint()..color = boxColor;
      canvas.drawCircle(rect.topLeft, 6, dot);
      canvas.drawCircle(rect.topRight, 6, dot);
      canvas.drawCircle(rect.bottomLeft, 6, dot);
      canvas.drawCircle(rect.bottomRight, 6, dot);
    }
  }

  Rect _translateRect(Rect rect, Size imageSize, Size widgetSize) {
    final sx = widgetSize.width / imageSize.width;
    final sy = widgetSize.height / imageSize.height;
    double left = rect.left * sx;
    double top = rect.top * sy;
    double right = rect.right * sx;
    double bottom = rect.bottom * sy;
    if (lensDirection == CameraLensDirection.front) {
      final tmp = left;
      left = widgetSize.width - right;
      right = widgetSize.width - tmp;
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  @override
  bool shouldRepaint(ObjectDetectorPainter old) =>
      old.objects != objects ||
      old.imageSize != imageSize ||
      old.levelColor != levelColor;
}

// ═══════════════════════════════════════════════════════════════════════════════
// CARD OVERLAY SNAPSHOT (unchanged — used by ConfirmationScreen & ResultScreen)
// ═══════════════════════════════════════════════════════════════════════════════

class CardOverlaySnapshot {
  static const double guideInnerInset = 20.0;

  final Size coordinateSize;
  final Rect outerGuideRect;
  final Rect innerGuideRect;

  const CardOverlaySnapshot({
    required this.coordinateSize,
    required this.outerGuideRect,
    required this.innerGuideRect,
  });

  CardOverlaySnapshot forResultDisplay() => this;

  static Rect innerRectFromOuter(
    Rect outer,
    Size bounds, {
    double inset = guideInnerInset,
    double insetScaleX = 1.0,
    double insetScaleY = 1.0,
  }) {
    final dx = inset * insetScaleX;
    final dy = inset * insetScaleY;
    var left = outer.left + dx;
    var top = outer.top + dy;
    var right = outer.right - dx;
    var bottom = outer.bottom - dy;

    if (right - left < 12 || bottom - top < 12) {
      final fb = inset.clamp(0.0, outer.shortestSide / 4);
      left = outer.left + fb;
      top = outer.top + fb;
      right = outer.right - fb;
      bottom = outer.bottom - fb;
    }

    return Rect.fromLTRB(
      left.clamp(outer.left, bounds.width),
      top.clamp(outer.top, bounds.height),
      right.clamp(outer.left, bounds.width),
      bottom.clamp(outer.top, bounds.height),
    );
  }

  factory CardOverlaySnapshot.fromApi(
    ApiCardDetection detection,
    Size imageSize,
  ) {
    final outer =
        detection.outerBox ??
        Rect.fromLTWH(0, 0, imageSize.width, imageSize.height);
    return CardOverlaySnapshot(
      coordinateSize: imageSize,
      outerGuideRect: outer,
      innerGuideRect: innerRectFromOuter(outer, imageSize),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// CONFIRMATION SCREEN (unchanged from your working version — keeping all logic)
// ═══════════════════════════════════════════════════════════════════════════════

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

class _CropResult {
  final File file;
  final Size croppedSize;
  final Rect sourcePixelCropRect;

  const _CropResult({
    required this.file,
    required this.croppedSize,
    required this.sourcePixelCropRect,
  });
}

class _ConfirmationScreenState extends State<ConfirmationScreen> {
  bool _isUploading = false;
  bool _isApiCalling = false;
  double _apiProgress = 0;
  int _apiElapsedSec = 0;
  int? _lastApiResponseMs;
  String? _apiProgressMessage;
  Timer? _apiProgressTimer;
  Stopwatch? _apiStopwatch;

  /// Typical HF Space cold/warm response — progress bar targets this duration.
  static const int _apiExpectedSec = 25;

  String? _croppedPath;
  Rect? _detectedRectOriginal;
  Rect? _firstCropRect;
  Rect? _guideOuterRect;
  Rect? _guideInnerRect;
  Rect? _initialOuterGuide;
  Rect? _initialInnerGuide;
  Size? _previewCoordinateSize;
  bool _isFirstCropApplied = false;
  List<Offset>? _opencvCorners;
  CardCornerValidation? _cornerValidation;
  bool _isAutoScanning = false;

  static const double _guideInnerInset = 20.0;
  static const double _guideOuterInset = -15.0;
  static const double _minGap = 12.0;
  static const double _cropPaddingFactor = 0.15;

  @override
  void initState() {
    super.initState();
    _initializePreviewState();
  }

  @override
  void dispose() {
    _apiProgressTimer?.cancel();
    super.dispose();
  }

  void _startApiProgressTimer() {
    _apiProgressTimer?.cancel();
    _apiStopwatch = Stopwatch()..start();
    _apiElapsedSec = 0;
    _apiProgress = 0.02;
    _lastApiResponseMs = null;

    _apiProgressTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted || _apiStopwatch == null) return;
      final elapsedMs = _apiStopwatch!.elapsedMilliseconds;
      final sec = elapsedMs ~/ 1000;
      final t = (elapsedMs / (_apiExpectedSec * 1000)).clamp(0.0, 1.0);

      setState(() {
        _apiElapsedSec = sec;
        // Quick ramp for upload/connect, then ease toward 92% by expected time.
        if (t < 0.15) {
          _apiProgress = 0.02 + (t / 0.15) * 0.18;
        } else {
          _apiProgress = (0.20 + 0.72 * (1 - math.exp(-(t - 0.15) * 2.2)))
              .clamp(0.0, 0.92);
        }
        if (sec == 0) {
          _apiProgressMessage = 'Uploading image…';
        } else {
          _apiProgressMessage = 'Waiting for API response… ${sec}s';
        }
      });
    });
  }

  void _finishApiProgress(int responseMs) {
    _apiProgressTimer?.cancel();
    _apiStopwatch?.stop();
    if (!mounted) return;
    final secText = (responseMs / 1000).toStringAsFixed(1);
    setState(() {
      _lastApiResponseMs = responseMs;
      _apiProgress = 1.0;
      _apiElapsedSec = responseMs ~/ 1000;
      _apiProgressMessage = 'Response received in ${secText}s';
    });
  }

  void _clearApiProgress() {
    _apiProgressTimer?.cancel();
    _apiStopwatch = null;
    if (!mounted) return;
    setState(() {
      _isApiCalling = false;
      _apiProgress = 0;
      _apiElapsedSec = 0;
      _apiProgressMessage = null;
    });
  }

  Future<void> _initializePreviewState() async {
    final streamSize = widget.streamSize;
    final detectedRect = widget.detectedRect;
    if (streamSize == null || detectedRect == null) return;

    final photoSize = await _getImageSize(File(widget.imagePath));
    if (!mounted || photoSize.width <= 0) return;

    final scaleX = photoSize.width / streamSize.width;
    final scaleY = photoSize.height / streamSize.height;

    final detectedInPhoto = Rect.fromLTRB(
      (detectedRect.left * scaleX).clamp(0.0, photoSize.width),
      (detectedRect.top * scaleY).clamp(0.0, photoSize.height),
      (detectedRect.right * scaleX).clamp(0.0, photoSize.width),
      (detectedRect.bottom * scaleY).clamp(0.0, photoSize.height),
    );

    setState(() {
      _detectedRectOriginal = detectedInPhoto;
      _previewCoordinateSize = photoSize;
    });
  }

  Future<_CropResult?> _cropRectFromImage({
    required String sourcePath,
    required Rect cropRect,
    required Size coordinateSpace,
    required bool updatePreview,
    bool showLoading = true,
  }) async {
    if (showLoading && mounted) setState(() => _isUploading = true);
    try {
      final bytes = await File(sourcePath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      final original = img.bakeOrientation(decoded);

      final scaleX = original.width / coordinateSpace.width;
      final scaleY = original.height / coordinateSpace.height;

      final cropX = (cropRect.left * scaleX).round().clamp(
        0,
        original.width - 1,
      );
      final cropY = (cropRect.top * scaleY).round().clamp(
        0,
        original.height - 1,
      );
      final cropRight = (cropRect.right * scaleX).round().clamp(
        cropX + 1,
        original.width,
      );
      final cropBottom = (cropRect.bottom * scaleY).round().clamp(
        cropY + 1,
        original.height,
      );
      final cropW = math.max(1, cropRight - cropX);
      final cropH = math.max(1, cropBottom - cropY);

      final cropped = img.copyCrop(
        original,
        x: cropX,
        y: cropY,
        width: cropW,
        height: cropH,
      );
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/crop_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final croppedFile = File(path);
      await croppedFile.writeAsBytes(img.encodeJpg(cropped));

      if (updatePreview && mounted) setState(() => _croppedPath = path);

      return _CropResult(
        file: croppedFile,
        croppedSize: Size(cropW.toDouble(), cropH.toDouble()),
        sourcePixelCropRect: Rect.fromLTWH(
          cropX.toDouble(),
          cropY.toDouble(),
          cropW.toDouble(),
          cropH.toDouble(),
        ),
      );
    } catch (e) {
      debugPrint('Crop error: $e');
      return null;
    } finally {
      if (showLoading && mounted) setState(() => _isUploading = false);
    }
  }

  Future<CardOverlaySnapshot?> _overlaySnapshotForImage({
    required Size imageSize,
    _CropResult? finalCrop,
    Rect? outerInPreview,
  }) async {
    if (finalCrop != null &&
        outerInPreview != null &&
        _previewCoordinateSize != null) {
      final outer = Rect.fromLTWH(
        0,
        0,
        finalCrop.croppedSize.width,
        finalCrop.croppedSize.height,
      );
      return CardOverlaySnapshot(
        coordinateSize: finalCrop.croppedSize,
        outerGuideRect: outer,
        innerGuideRect: CardOverlaySnapshot.innerRectFromOuter(
          outer,
          finalCrop.croppedSize,
        ),
      );
    }
    if (_guideOuterRect != null && _previewCoordinateSize != null) {
      final sx = imageSize.width / _previewCoordinateSize!.width;
      final sy = imageSize.height / _previewCoordinateSize!.height;
      final outer = Rect.fromLTRB(
        _guideOuterRect!.left * sx,
        _guideOuterRect!.top * sy,
        _guideOuterRect!.right * sx,
        _guideOuterRect!.bottom * sy,
      );
      return CardOverlaySnapshot(
        coordinateSize: imageSize,
        outerGuideRect: outer,
        innerGuideRect: CardOverlaySnapshot.innerRectFromOuter(
          outer,
          imageSize,
          insetScaleX: sx,
          insetScaleY: sy,
        ),
      );
    }
    if (_detectedRectOriginal != null) {
      final outer = _detectedRectOriginal!.inflate(24);
      return CardOverlaySnapshot(
        coordinateSize: imageSize,
        outerGuideRect: outer,
        innerGuideRect: CardOverlaySnapshot.innerRectFromOuter(
          outer,
          imageSize,
        ),
      );
    }
    return null;
  }

  Future<void> _onCheckPressed() async {
    if (_isApiCalling || _isUploading) return;
    setState(() {
      _isUploading = true;
      _apiProgressMessage = 'Preparing image…';
    });
    try {
      File imageToUpload;
      _CropResult? finalCrop;
      Rect? outerUsedForCrop;
      CardOverlaySnapshot? overlaySnapshot;

      if (_isFirstCropApplied &&
          _guideOuterRect != null &&
          _previewCoordinateSize != null) {
        outerUsedForCrop = _guideOuterRect;
        finalCrop = await _cropRectFromImage(
          sourcePath: _croppedPath ?? widget.imagePath,
          cropRect: _guideOuterRect!,
          coordinateSpace: _previewCoordinateSize!,
          updatePreview: false,
          showLoading: false,
        );
        if (finalCrop == null) return;
        imageToUpload = finalCrop.file;
        overlaySnapshot = await _overlaySnapshotForImage(
          imageSize: finalCrop.croppedSize,
          finalCrop: finalCrop,
          outerInPreview: outerUsedForCrop,
        );
      } else {
        imageToUpload = File(_croppedPath ?? widget.imagePath);
        final imageSize = await _getImageSize(imageToUpload);
        overlaySnapshot = await _overlaySnapshotForImage(imageSize: imageSize);
      }

      if (!mounted) return;
      setState(() {
        _isUploading = false;
        _isApiCalling = true;
      });
      _startApiProgressTimer();

      final upload = await _uploadImage(imageToUpload);
      _finishApiProgress(upload.elapsedMs);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!mounted) return;

      final response = upload.body;

      final detection = ApiCardDetection.fromResponse(response);
      final apiMessage = response['message']?.toString();

      if (response['success'] == true && detection.isDetected) {
        if (overlaySnapshot == null) {
          final imageSize = await _getImageSize(imageToUpload);
          if (detection.hasGeometry) {
            overlaySnapshot = CardOverlaySnapshot.fromApi(detection, imageSize);
          }
        }
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => ResultScreen(
              imagePath: imageToUpload.path,
              apiResponse: response,
              overlay: overlaySnapshot?.forResultDisplay(),
            ),
          ),
        );
        return;
      }

      final failureMessage = apiMessage?.isNotEmpty == true
          ? apiMessage!
          : 'Not a card';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(failureMessage),
          duration: const Duration(seconds: 3),
        ),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      debugPrint('API Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isUploading = false);
        if (_isApiCalling) _clearApiProgress();
      }
    }
  }

  Future<({Map<String, dynamic> body, int elapsedMs})> _uploadImage(
    File imageFile,
  ) async {
    final sw = Stopwatch()..start();
    final req = http.MultipartRequest('POST', Uri.parse(kDetectCardEndpoint));
    if (kHfApiToken.isNotEmpty)
      req.headers['Authorization'] = 'Bearer $kHfApiToken';
    req.files.add(
      await http.MultipartFile.fromPath(
        'file',
        imageFile.path,
        contentType: MediaType('image', 'jpeg'),
      ),
    );
    final res = await http.Response.fromStream(await req.send());
    sw.stop();
    debugPrint('API (${sw.elapsedMilliseconds}ms): ${res.body}');
    Map<String, dynamic> body;
    if (res.statusCode == 200) {
      final decoded = json.decode(res.body);
      body = decoded is Map<String, dynamic>
          ? decoded
          : {'success': false, 'message': 'Invalid response'};
    } else {
      body = {'success': false, 'message': 'Server error ${res.statusCode}'};
    }
    return (body: body, elapsedMs: sw.elapsedMilliseconds);
  }

  void _setGuideRectsAroundCard({
    required Rect detectedRect,
    required Rect firstCropRect,
    required Size croppedSize,
  }) {
    final local = Rect.fromLTRB(
      detectedRect.left - firstCropRect.left,
      detectedRect.top - firstCropRect.top,
      detectedRect.right - firstCropRect.left,
      detectedRect.bottom - firstCropRect.top,
    );
    final sx = croppedSize.width / firstCropRect.width;
    final sy = croppedSize.height / firstCropRect.height;
    final cardInCrop = Rect.fromLTRB(
      local.left * sx,
      local.top * sy,
      local.right * sx,
      local.bottom * sy,
    );

    final pad = _guideOuterInset;
    final outerLeft = (cardInCrop.left - pad).clamp(0.0, croppedSize.width);
    final outerTop = (cardInCrop.top - pad).clamp(0.0, croppedSize.height);
    final outerRight = (cardInCrop.right + pad).clamp(0.0, croppedSize.width);
    final outerBottom = (cardInCrop.bottom + pad).clamp(
      0.0,
      croppedSize.height,
    );

    _guideOuterRect = Rect.fromLTRB(
      outerLeft,
      outerTop,
      math.max(outerLeft + _minGap, outerRight),
      math.max(outerTop + _minGap, outerBottom),
    );
    _guideInnerRect = _innerRectFromOuter(_guideOuterRect!, croppedSize);
  }

  Rect _innerRectFromOuter(Rect outer, Size bounds) =>
      CardOverlaySnapshot.innerRectFromOuter(outer, bounds);

  void _onOuterGuideChanged(Rect outer) {
    final bounds = _previewCoordinateSize;
    if (bounds == null) return;
    final clamped = Rect.fromLTRB(
      outer.left.clamp(0.0, bounds.width - _minGap),
      outer.top.clamp(0.0, bounds.height - _minGap),
      outer.right.clamp(outer.left + _minGap, bounds.width),
      outer.bottom.clamp(outer.top + _minGap, bounds.height),
    );
    setState(() {
      _guideOuterRect = clamped;
      _guideInnerRect = _innerRectFromOuter(clamped, bounds);
    });
  }

  bool _consumeOpenCvResult(
    CardCornerDetectionResult result, {
    required VoidCallback onValid,
  }) {
    setState(() => _cornerValidation = result.cornerValidation);
    if (!result.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.errorMessage ?? 'Card not detected — retake or rescan',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
      return false;
    }
    onValid();
    return true;
  }

  Future<void> _handleAutoScan() async {
    if (_isAutoScanning || _isUploading) return;
    setState(() => _isAutoScanning = true);
    try {
      final sourcePath = _croppedPath ?? widget.imagePath;
      final hint = _isFirstCropApplied ? null : _detectedRectOriginal;

      final result = await CardCornerDetector.detectFromFile(
        File(sourcePath),
        searchRegion: hint,
        outerPadding: _isFirstCropApplied ? 0 : _guideOuterInset.abs(),
      );
      if (!mounted) return;

      if (!_isFirstCropApplied) {
        if (!_consumeOpenCvResult(result, onValid: () {})) return;
        final photoSize =
            _previewCoordinateSize ??
            await _getImageSize(File(widget.imagePath));
        if (!mounted) return;
        setState(() {
          _detectedRectOriginal = _boundsFromCorners(result.corners);
          _opencvCorners = result.corners;
          _previewCoordinateSize = photoSize;
        });
        await _handleFirstCrop();
        if (!mounted || !_isFirstCropApplied) return;
        final refined = await CardCornerDetector.detectFromFile(
          File(_croppedPath!),
          outerPadding: _guideInnerInset,
        );
        if (!mounted) return;
        _consumeOpenCvResult(
          refined,
          onValid: () {
            final bounds = _previewCoordinateSize;
            if (bounds == null) return;
            final refinedBounds = _boundsFromCorners(refined.corners);
            setState(() {
              _guideOuterRect = refinedBounds;
              _guideInnerRect = _innerRectFromOuter(refinedBounds, bounds);
              _opencvCorners = refined.corners;
              _initialOuterGuide = _guideOuterRect;
              _initialInnerGuide = _guideInnerRect;
            });
          },
        );
      } else {
        _consumeOpenCvResult(
          result,
          onValid: () {
            final bounds = _previewCoordinateSize;
            if (bounds == null) return;
            final rb = _boundsFromCorners(result.corners);
            setState(() {
              _guideOuterRect = rb;
              _guideInnerRect = _innerRectFromOuter(rb, bounds);
              _opencvCorners = result.corners;
            });
          },
        );
      }
    } catch (e) {
      debugPrint('Auto Scan: $e');
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Auto scan failed')));
    } finally {
      if (mounted) setState(() => _isAutoScanning = false);
    }
  }

  Rect _boundsFromCorners(List<Offset> corners) {
    double minX = corners.first.dx, maxX = corners.first.dx;
    double minY = corners.first.dy, maxY = corners.first.dy;
    for (final p in corners) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  Future<void> _handleFirstCrop() async {
    final detectedRect = _detectedRectOriginal;
    final previewCoordinateSize = _previewCoordinateSize;
    if (_isFirstCropApplied ||
        detectedRect == null ||
        previewCoordinateSize == null)
      return;

    final padX = detectedRect.width * _cropPaddingFactor;
    final padY = detectedRect.height * _cropPaddingFactor;
    final firstCropRect = Rect.fromLTRB(
      math.max(0, detectedRect.left - padX),
      math.max(0, detectedRect.top - padY),
      math.min(previewCoordinateSize.width, detectedRect.right + padX),
      math.min(previewCoordinateSize.height, detectedRect.bottom + padY),
    );

    final cropped = await _cropRectFromImage(
      sourcePath: widget.imagePath,
      cropRect: firstCropRect,
      coordinateSpace: previewCoordinateSize,
      updatePreview: true,
    );
    if (cropped == null || !mounted) return;

    _setGuideRectsAroundCard(
      detectedRect: detectedRect,
      firstCropRect: firstCropRect,
      croppedSize: cropped.croppedSize,
    );

    setState(() {
      _isFirstCropApplied = true;
      _firstCropRect = firstCropRect;
      _previewCoordinateSize = cropped.croppedSize;
      _initialOuterGuide = _guideOuterRect;
      _initialInnerGuide = _guideInnerRect;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Preview'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(child: _buildImageArea()),
              _buildButtonBar(),
              if (_cornerValidation != null) _buildCornerValidationChip(),
              if (_isFirstCropApplied &&
                  _croppedPath != null &&
                  _guideOuterRect != null &&
                  _guideInnerRect != null)
                _buildMetricRow(),
            ],
          ),
          if (_isApiCalling) _buildApiProgressOverlay(),
        ],
      ),
    );
  }

  Widget _buildApiProgressOverlay() {
    final pct = (_apiProgress * 100).round().clamp(0, 100);
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.78),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 36),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _apiProgress,
                    minHeight: 8,
                    backgroundColor: Colors.white24,
                    color: const Color(0xFF7B61FF),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  _apiProgressMessage ?? 'Please wait…',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '$pct% · ${_apiElapsedSec}s elapsed · typical ~$_apiExpectedSec s',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
                if (_lastApiResponseMs != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Response time: ${(_lastApiResponseMs! / 1000).toStringAsFixed(1)} s',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF3DDC84),
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImageArea() {
    if (_isFirstCropApplied &&
        _croppedPath != null &&
        _guideOuterRect != null &&
        _guideInnerRect != null &&
        _previewCoordinateSize != null) {
      return Center(
        child: FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: _previewCoordinateSize!.width,
            height: _previewCoordinateSize!.height,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Image.file(
                  File(_croppedPath!),
                  key: ValueKey(_croppedPath),
                  width: _previewCoordinateSize!.width,
                  height: _previewCoordinateSize!.height,
                  fit: BoxFit.fill,
                ),
                SecondStageCropOverlay(
                  imageBounds: Rect.fromLTWH(
                    0,
                    0,
                    _previewCoordinateSize!.width,
                    _previewCoordinateSize!.height,
                  ),
                  coordinateSize: _previewCoordinateSize!,
                  outerGuideRect: _guideOuterRect!,
                  innerGuideRect: _guideInnerRect!,
                  onOuterChanged: _onOuterGuideChanged,
                  onInnerChanged: (r) => setState(() => _guideInnerRect = r),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Stack(
      children: [
        Center(
          child: Image.file(
            File(_croppedPath ?? widget.imagePath),
            key: ValueKey(_croppedPath),
            fit: BoxFit.contain,
          ),
        ),
        if (!_isFirstCropApplied &&
            _detectedRectOriginal != null &&
            _previewCoordinateSize != null)
          Positioned.fill(
            child: LayoutBuilder(
              builder: (ctx, constraints) {
                return FutureBuilder<Size>(
                  future: _getImageSize(File(widget.imagePath)),
                  builder: (ctx, snap) {
                    if (!snap.hasData) return const SizedBox.shrink();
                    final displayRect = _getDisplayedImageRect(
                      containerSize: Size(
                        constraints.maxWidth,
                        constraints.maxHeight,
                      ),
                      imageSize: snap.data!,
                    );
                    return CropEditorOverlay(
                      imageBounds: displayRect,
                      coordinateSize: _previewCoordinateSize!,
                      detectedRect: _detectedRectOriginal!,
                      onBackgroundTap: _handleFirstCrop,
                    );
                  },
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildButtonBar() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: const BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: (_isUploading && !_isApiCalling) || _isAutoScanning
          ? const Center(child: CircularProgressIndicator())
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: (_isApiCalling || _isUploading)
                            ? null
                            : () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          side: const BorderSide(color: Colors.white, width: 2),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: _label('Retake', Colors.white),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _isFirstCropApplied
                            ? () {
                                if (_initialOuterGuide != null &&
                                    _previewCoordinateSize != null) {
                                  setState(() {
                                    _guideOuterRect = _initialOuterGuide;
                                    _guideInnerRect = _innerRectFromOuter(
                                      _initialOuterGuide!,
                                      _previewCoordinateSize!,
                                    );
                                  });
                                }
                              }
                            : _handleFirstCrop,
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          backgroundColor: const Color(0xFF4A80F0),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: _label('ML Crop', Colors.white),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: (_isApiCalling || _isUploading)
                            ? null
                            : _onCheckPressed,
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          backgroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: _label('API Check', Colors.black),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: (_isApiCalling || _isUploading)
                        ? null
                        : _handleAutoScan,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      side: const BorderSide(color: Colors.white, width: 2),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(
                      Icons.document_scanner_outlined,
                      color: Colors.white,
                      size: 20,
                    ),
                    label: _label('OpenCV Auto Scan', Colors.white),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _label(String text, Color color) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    textAlign: TextAlign.center,
    style: TextStyle(
      color: color,
      fontSize: 14,
      fontWeight: FontWeight.bold,
      letterSpacing: 0.2,
    ),
  );

  Widget _buildCornerValidationChip() {
    final v = _cornerValidation!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: v.isValid ? const Color(0xFF1A3324) : const Color(0xFF3A1A1A),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: v.isValid
                ? const Color(0xFF3DDC84)
                : const Color(0xFFFF5252),
            width: 1.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              v.isValid
                  ? 'OpenCV corners valid'
                  : 'OpenCV corners invalid — rescan',
              style: TextStyle(
                color: v.isValid
                    ? const Color(0xFF3DDC84)
                    : const Color(0xFFFF5252),
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Max X/Y defect: ${v.maxAxisDefectPx.toStringAsFixed(1)} px '
              '(limit ${CardCornerValidator.maxDefect.toInt()}) · '
              'Max angle: ${v.maxAngleDefectDeg.toStringAsFixed(1)}° '
              '(limit ${CardCornerValidator.maxDefect.toInt()})',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Row(
        children: [
          Expanded(
            child: _metricCard(
              'Horizontal',
              _formatSplit(
                _guideInnerRect!.left - _guideOuterRect!.left,
                _guideOuterRect!.right - _guideInnerRect!.right,
              ),
              Icons.swap_horiz,
              'Left · Right',
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _metricCard(
              'Vertical',
              _formatSplit(
                _guideInnerRect!.top - _guideOuterRect!.top,
                _guideOuterRect!.bottom - _guideInnerRect!.bottom,
              ),
              Icons.swap_vert,
              'Top · Bottom',
            ),
          ),
        ],
      ),
    );
  }

  Widget _metricCard(
    String title,
    String value,
    IconData icon,
    String subtitle,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF7B61FF), size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatSplit(double a, double b) {
    final total = a + b;
    if (total <= 0) return '50.0/50.0';
    return '${((a / total) * 100).toStringAsFixed(1)}/${((b / total) * 100).toStringAsFixed(1)}';
  }

  Rect _getDisplayedImageRect({
    required Size containerSize,
    required Size imageSize,
  }) {
    final scale = math.min(
      containerSize.width / imageSize.width,
      containerSize.height / imageSize.height,
    );
    return Rect.fromLTWH(
      (containerSize.width - imageSize.width * scale) / 2,
      (containerSize.height - imageSize.height * scale) / 2,
      imageSize.width * scale,
      imageSize.height * scale,
    );
  }

  Future<Size> _getImageSize(File file) async {
    final bytes = await file.readAsBytes();
    final decoded = img.decodeImage(bytes);
    final image = decoded == null ? null : img.bakeOrientation(decoded);
    return image == null
        ? const Size(0, 0)
        : Size(image.width.toDouble(), image.height.toDouble());
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// CROP EDITOR OVERLAY (Phase 1 — full photo)
// ═══════════════════════════════════════════════════════════════════════════════

class CropEditorOverlay extends StatelessWidget {
  final Rect imageBounds;
  final Size coordinateSize;
  final Rect detectedRect;
  final VoidCallback onBackgroundTap;

  const CropEditorOverlay({
    super.key,
    required this.imageBounds,
    required this.coordinateSize,
    required this.detectedRect,
    required this.onBackgroundTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: onBackgroundTap,
      child: CustomPaint(
        painter: CropOverlayPainter(
          imageBounds: imageBounds,
          coordinateSize: coordinateSize,
          detectedRect: detectedRect,
        ),
      ),
    );
  }
}

class CropOverlayPainter extends CustomPainter {
  final Rect imageBounds;
  final Size coordinateSize;
  final Rect detectedRect;

  const CropOverlayPainter({
    required this.imageBounds,
    required this.coordinateSize,
    required this.detectedRect,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final sx = imageBounds.width / coordinateSize.width;
    final sy = imageBounds.height / coordinateSize.height;
    final displayRect = Rect.fromLTRB(
      imageBounds.left + detectedRect.left * sx,
      imageBounds.top + detectedRect.top * sy,
      imageBounds.left + detectedRect.right * sx,
      imageBounds.top + detectedRect.bottom * sy,
    );
    canvas.drawRect(
      displayRect,
      Paint()
        ..color = Colors.deepPurpleAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(CropOverlayPainter old) =>
      old.detectedRect != detectedRect;
}

// ═══════════════════════════════════════════════════════════════════════════════
// SECOND STAGE CROP OVERLAY (Phase 2 — cropped image with draggable guides)
// ═══════════════════════════════════════════════════════════════════════════════

class SecondStageCropOverlay extends StatelessWidget {
  final Rect imageBounds;
  final Size coordinateSize;
  final Rect outerGuideRect;
  final Rect innerGuideRect;
  final ValueChanged<Rect> onOuterChanged;
  final ValueChanged<Rect> onInnerChanged;

  const SecondStageCropOverlay({
    super.key,
    required this.imageBounds,
    required this.coordinateSize,
    required this.outerGuideRect,
    required this.innerGuideRect,
    required this.onOuterChanged,
    required this.onInnerChanged,
  });

  Offset _toDisplay(Offset point) {
    final sx = imageBounds.width / coordinateSize.width;
    final sy = imageBounds.height / coordinateSize.height;
    return Offset(
      imageBounds.left + point.dx * sx,
      imageBounds.top + point.dy * sy,
    );
  }

  double _dx(double delta) => delta * coordinateSize.width / imageBounds.width;

  double _dy(double delta) =>
      delta * coordinateSize.height / imageBounds.height;

  static const double _minGap = 12.0;
  static const double _innerInset = 20.0;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: GuideBoxesPainter(
              coordinateSize: coordinateSize,
              outerGuideRect: outerGuideRect,
              innerGuideRect: innerGuideRect,
            ),
          ),
        ),

        // Outer corners
        _corner(
          _toDisplay(Offset(outerGuideRect.left, outerGuideRect.top)),
          const Color(0xFF7B61FF),
          (d) {
            onOuterChanged(
              Rect.fromLTRB(
                (outerGuideRect.left + _dx(d.delta.dx)).clamp(
                  0,
                  outerGuideRect.right - _minGap,
                ),
                (outerGuideRect.top + _dy(d.delta.dy)).clamp(
                  0,
                  outerGuideRect.bottom - _minGap,
                ),
                outerGuideRect.right,
                outerGuideRect.bottom,
              ),
            );
          },
        ),
        _corner(
          _toDisplay(Offset(outerGuideRect.right, outerGuideRect.top)),
          const Color(0xFF7B61FF),
          (d) {
            onOuterChanged(
              Rect.fromLTRB(
                outerGuideRect.left,
                (outerGuideRect.top + _dy(d.delta.dy)).clamp(
                  0,
                  outerGuideRect.bottom - _minGap,
                ),
                (outerGuideRect.right + _dx(d.delta.dx)).clamp(
                  outerGuideRect.left + _minGap,
                  coordinateSize.width,
                ),
                outerGuideRect.bottom,
              ),
            );
          },
        ),
        _corner(
          _toDisplay(Offset(outerGuideRect.right, outerGuideRect.bottom)),
          const Color(0xFF7B61FF),
          (d) {
            onOuterChanged(
              Rect.fromLTRB(
                outerGuideRect.left,
                outerGuideRect.top,
                (outerGuideRect.right + _dx(d.delta.dx)).clamp(
                  outerGuideRect.left + _minGap,
                  coordinateSize.width,
                ),
                (outerGuideRect.bottom + _dy(d.delta.dy)).clamp(
                  outerGuideRect.top + _minGap,
                  coordinateSize.height,
                ),
              ),
            );
          },
        ),
        _corner(
          _toDisplay(Offset(outerGuideRect.left, outerGuideRect.bottom)),
          const Color(0xFF7B61FF),
          (d) {
            onOuterChanged(
              Rect.fromLTRB(
                (outerGuideRect.left + _dx(d.delta.dx)).clamp(
                  0,
                  outerGuideRect.right - _minGap,
                ),
                outerGuideRect.top,
                outerGuideRect.right,
                (outerGuideRect.bottom + _dy(d.delta.dy)).clamp(
                  outerGuideRect.top + _minGap,
                  coordinateSize.height,
                ),
              ),
            );
          },
        ),

        // Outer edge handles
        _handle(
          _toDisplay(
            Offset(
              (outerGuideRect.left + outerGuideRect.right) / 2,
              outerGuideRect.top,
            ),
          ),
          Icons.keyboard_arrow_up,
          const Color(0xFF7B61FF),
          (d) {
            onOuterChanged(
              Rect.fromLTRB(
                outerGuideRect.left,
                (outerGuideRect.top + _dy(d.delta.dy)).clamp(
                  0,
                  outerGuideRect.bottom - _minGap - _innerInset * 2,
                ),
                outerGuideRect.right,
                outerGuideRect.bottom,
              ),
            );
          },
        ),
        _handle(
          _toDisplay(
            Offset(
              (outerGuideRect.left + outerGuideRect.right) / 2,
              outerGuideRect.bottom,
            ),
          ),
          Icons.keyboard_arrow_down,
          const Color(0xFF7B61FF),
          (d) {
            onOuterChanged(
              Rect.fromLTRB(
                outerGuideRect.left,
                outerGuideRect.top,
                outerGuideRect.right,
                (outerGuideRect.bottom + _dy(d.delta.dy)).clamp(
                  outerGuideRect.top + _minGap + _innerInset * 2,
                  coordinateSize.height,
                ),
              ),
            );
          },
        ),
        _handle(
          _toDisplay(
            Offset(
              outerGuideRect.left,
              (outerGuideRect.top + outerGuideRect.bottom) / 2,
            ),
          ),
          Icons.keyboard_arrow_left,
          const Color(0xFF7B61FF),
          (d) {
            onOuterChanged(
              Rect.fromLTRB(
                (outerGuideRect.left + _dx(d.delta.dx)).clamp(
                  0,
                  outerGuideRect.right - _minGap - _innerInset * 2,
                ),
                outerGuideRect.top,
                outerGuideRect.right,
                outerGuideRect.bottom,
              ),
            );
          },
        ),
        _handle(
          _toDisplay(
            Offset(
              outerGuideRect.right,
              (outerGuideRect.top + outerGuideRect.bottom) / 2,
            ),
          ),
          Icons.keyboard_arrow_right,
          const Color(0xFF7B61FF),
          (d) {
            onOuterChanged(
              Rect.fromLTRB(
                outerGuideRect.left,
                outerGuideRect.top,
                (outerGuideRect.right + _dx(d.delta.dx)).clamp(
                  outerGuideRect.left + _minGap + _innerInset * 2,
                  coordinateSize.width,
                ),
                outerGuideRect.bottom,
              ),
            );
          },
        ),

        // Inner edge handles
        _handle(
          _toDisplay(
            Offset(
              (innerGuideRect.left + innerGuideRect.right) / 2,
              innerGuideRect.top,
            ),
          ),
          Icons.keyboard_arrow_down,
          const Color(0xFF3DDC84),
          (d) {
            onInnerChanged(
              Rect.fromLTRB(
                innerGuideRect.left,
                (innerGuideRect.top + _dy(d.delta.dy)).clamp(
                  outerGuideRect.top + _minGap,
                  innerGuideRect.bottom - _minGap,
                ),
                innerGuideRect.right,
                innerGuideRect.bottom,
              ),
            );
          },
        ),
        _handle(
          _toDisplay(
            Offset(
              (innerGuideRect.left + innerGuideRect.right) / 2,
              innerGuideRect.bottom,
            ),
          ),
          Icons.keyboard_arrow_up,
          const Color(0xFF3DDC84),
          (d) {
            onInnerChanged(
              Rect.fromLTRB(
                innerGuideRect.left,
                innerGuideRect.top,
                innerGuideRect.right,
                (innerGuideRect.bottom + _dy(d.delta.dy)).clamp(
                  innerGuideRect.top + _minGap,
                  outerGuideRect.bottom - _minGap,
                ),
              ),
            );
          },
        ),
        _handle(
          _toDisplay(
            Offset(
              innerGuideRect.left,
              (innerGuideRect.top + innerGuideRect.bottom) / 2,
            ),
          ),
          Icons.keyboard_arrow_right,
          const Color(0xFF3DDC84),
          (d) {
            onInnerChanged(
              Rect.fromLTRB(
                (innerGuideRect.left + _dx(d.delta.dx)).clamp(
                  outerGuideRect.left + _minGap,
                  innerGuideRect.right - _minGap,
                ),
                innerGuideRect.top,
                innerGuideRect.right,
                innerGuideRect.bottom,
              ),
            );
          },
        ),
        _handle(
          _toDisplay(
            Offset(
              innerGuideRect.right,
              (innerGuideRect.top + innerGuideRect.bottom) / 2,
            ),
          ),
          Icons.keyboard_arrow_left,
          const Color(0xFF3DDC84),
          (d) {
            onInnerChanged(
              Rect.fromLTRB(
                innerGuideRect.left,
                innerGuideRect.top,
                (innerGuideRect.right + _dx(d.delta.dx)).clamp(
                  innerGuideRect.left + _minGap,
                  outerGuideRect.right - _minGap,
                ),
                innerGuideRect.bottom,
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _handle(
    Offset pt,
    IconData icon,
    Color color,
    GestureDragUpdateCallback onDrag,
  ) {
    const sz = 32.0;
    return Positioned(
      left: pt.dx - sz / 2,
      top: pt.dy - sz / 2,
      child: GestureDetector(
        onPanUpdate: onDrag,
        child: Container(
          width: sz,
          height: sz,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(10),
            boxShadow: const [
              BoxShadow(
                color: Colors.black45,
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Icon(icon, color: Colors.white, size: 18),
        ),
      ),
    );
  }

  Widget _corner(Offset pt, Color color, GestureDragUpdateCallback onDrag) {
    const sz = 10.0;
    return Positioned(
      left: pt.dx - sz / 2,
      top: pt.dy - sz / 2,
      child: GestureDetector(
        onPanUpdate: onDrag,
        child: Container(
          width: sz,
          height: sz,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            boxShadow: const [
              BoxShadow(
                color: Colors.black45,
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// GUIDE BOXES PAINTER
// ═══════════════════════════════════════════════════════════════════════════════

class GuideBoxesPainter extends CustomPainter {
  final Size coordinateSize;
  final Rect outerGuideRect;
  final Rect innerGuideRect;

  const GuideBoxesPainter({
    required this.coordinateSize,
    required this.outerGuideRect,
    required this.innerGuideRect,
  });

  Rect _scale(Rect r, Size s) {
    final sx = s.width / coordinateSize.width;
    final sy = s.height / coordinateSize.height;
    return Rect.fromLTRB(r.left * sx, r.top * sy, r.right * sx, r.bottom * sy);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final outer = _scale(outerGuideRect, size);
    final inner = _scale(innerGuideRect, size);

    // Dim outside
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRect(outer),
      ),
      Paint()..color = Colors.black.withOpacity(0.45),
    );

    // Hatch band between outer and inner
    final band = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(outer)
      ..addRect(inner);
    canvas.save();
    canvas.clipPath(band);
    final hatch = Paint()
      ..color = const Color(0xFF4A80F0).withOpacity(0.55)
      ..strokeWidth = 1.5;
    const spacing = 10.0;
    for (
      double x = outer.left - outer.height;
      x < outer.right + outer.height;
      x += spacing
    ) {
      canvas.drawLine(
        Offset(x, outer.top),
        Offset(x + outer.height, outer.bottom),
        hatch,
      );
    }
    for (double x = outer.left; x < outer.right + outer.height; x += spacing) {
      canvas.drawLine(
        Offset(x, outer.bottom),
        Offset(x - outer.height, outer.top),
        hatch,
      );
    }
    canvas.restore();

    canvas.drawRect(
      outer,
      Paint()
        ..color = const Color(0xFF7B61FF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    canvas.drawRect(
      inner,
      Paint()
        ..color = const Color(0xFF3DDC84)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(GuideBoxesPainter old) =>
      old.outerGuideRect != outerGuideRect ||
      old.innerGuideRect != innerGuideRect;
}

// ═══════════════════════════════════════════════════════════════════════════════
// RESULT SCREEN
// ═══════════════════════════════════════════════════════════════════════════════

class ResultScreen extends StatelessWidget {
  final String imagePath;
  final Map<String, dynamic> apiResponse;
  final CardOverlaySnapshot? overlay;

  const ResultScreen({
    super.key,
    required this.imagePath,
    required this.apiResponse,
    this.overlay,
  });

  @override
  Widget build(BuildContext context) {
    final message = apiResponse['message']?.toString() ?? 'Card detected';
    final detection = ApiCardDetection.fromResponse(apiResponse);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Card Detected'),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Column(
        children: [
          Expanded(
            child: CardResultPreview(
              imagePath: imagePath,
              detection: detection,
              overlay: overlay,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          _ApiMatchInfoPanel(detection: detection),
          Padding(
            padding: const EdgeInsets.all(24),
            child: ElevatedButton(
              onPressed: () => Navigator.popUntil(context, (r) => r.isFirst),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 50),
                backgroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                'Back to Camera',
                style: TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ApiMatchInfoPanel extends StatelessWidget {
  final ApiCardDetection detection;

  const _ApiMatchInfoPanel({required this.detection});

  @override
  Widget build(BuildContext context) {
    final rawName = detection.matchedCard ?? 'Unknown card';
    final cardName = rawName.contains('/') ? rawName.split('/').last : rawName;
    final score = detection.similarityScore;
    final margin = detection.margin;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Match',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            cardName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (score != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _chip(
                    'Similarity',
                    '${(score * 100).toStringAsFixed(1)}%',
                  ),
                ),
                if (margin != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: _chip(
                      'Margin',
                      '${(margin * 100).toStringAsFixed(1)}%',
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _chip(String label, String value) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: const Color(0xFF222222),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

class CardResultPreview extends StatelessWidget {
  final String imagePath;
  final ApiCardDetection detection;
  final CardOverlaySnapshot? overlay;

  const CardResultPreview({
    super.key,
    required this.imagePath,
    required this.detection,
    this.overlay,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Size>(
      future: _getSize(),
      builder: (ctx, snap) {
        if (!snap.hasData || snap.data == Size.zero)
          return const Center(child: CircularProgressIndicator());
        final imageSize = snap.data!;
        final snap2 =
            overlay ??
            (detection.hasGeometry
                ? CardOverlaySnapshot.fromApi(detection, imageSize)
                : _defaultOverlay(imageSize));
        final ov = snap2.forResultDisplay();
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: imageSize.width,
                height: imageSize.height,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Image.file(
                      File(imagePath),
                      width: imageSize.width,
                      height: imageSize.height,
                      fit: BoxFit.fill,
                    ),
                    Positioned.fill(
                      child: CustomPaint(
                        painter: GuideBoxesPainter(
                          coordinateSize: ov.coordinateSize,
                          outerGuideRect: ov.outerGuideRect,
                          innerGuideRect: ov.innerGuideRect,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  CardOverlaySnapshot _defaultOverlay(Size imageSize) {
    final outer = Rect.fromLTWH(0, 0, imageSize.width, imageSize.height);
    return CardOverlaySnapshot(
      coordinateSize: imageSize,
      outerGuideRect: outer,
      innerGuideRect: CardOverlaySnapshot.innerRectFromOuter(outer, imageSize),
    );
  }

  Future<Size> _getSize() async {
    final bytes = await File(imagePath).readAsBytes();
    final decoded = img.decodeImage(bytes);
    final image = decoded == null ? null : img.bakeOrientation(decoded);
    return image == null
        ? Size.zero
        : Size(image.width.toDouble(), image.height.toDouble());
  }
}
