import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
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

  DetectedObject? _detectedObject;
  Size? _imageSize;
  InputImageRotation? _rotation;

  // Sensor / gyroscope level variables
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;
  double _rollDeg = 0;
  double _pitchDeg = 0;
  bool _isDeviceLevel = false;
  bool _isHorizontalLevel = false;
  bool _isVerticalLevel = false;
  bool _showSpiritLevel = true;

  @override
  void initState() {
    super.initState();
    _initialize();
    _startSensorTracking();
  }

  void _startSensorTracking() {
    _accelerometerSubscription = accelerometerEvents.listen((
      AccelerometerEvent event,
    ) {
      if (!mounted) return;

      double x = event.x;
      double y = event.y;
      double z = event.z;

      // Calculate the angle from the Z-axis (how "flat" the phone is)
      double tilt =
          math.acos(z / math.sqrt(x * x + y * y + z * z)) * (180 / math.pi);

      final roll = math.atan2(x, z) * (180 / math.pi);
      final pitch = math.atan2(y, z) * (180 / math.pi);

      setState(() {
        _rollDeg = roll;
        _pitchDeg = pitch;
        _isHorizontalLevel = roll.abs() < 8.0;
        _isVerticalLevel = pitch.abs() < 8.0;
        _isDeviceLevel =
            tilt < 10.0 && _isHorizontalLevel && _isVerticalLevel;
      });
    });
  }

  Future<void> _initialize() async {
    final cameras = await availableCameras();
    final backCamera = cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.back,
    );

    _cameraController = CameraController(
      backCamera,
      ResolutionPreset.medium, // Optimized for performance
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );

    await _cameraController!.initialize();
    await _cameraController!.setFlashMode(FlashMode.off); // Ensure flash is off
    await _cameraController!.lockCaptureOrientation(
      DeviceOrientation.portraitUp,
    );

    _objectDetector = ObjectDetector(
      options: ObjectDetectorOptions(
        mode: DetectionMode.stream,
        classifyObjects: false, // Focused on detection
        multipleObjects: false, // Single object mode for accuracy
      ),
    );

    await _cameraController!.startImageStream(_processCameraImage);

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isProcessing || _isCapturing || !_isDeviceLevel) {
      if (!_isDeviceLevel && _detectedObject != null) {
        setState(() {
          _detectedObject = null;
        });
      }
      return;
    }

    // Performance Optimization: Process detection only ~5 times per second
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastProcessTime != null && now - _lastProcessTime! < 200) {
      return;
    }
    _lastProcessTime = now;

    _isProcessing = true;

    try {
      final inputImage = _inputImageFromCameraImage(image);
      if (inputImage == null) {
        _isProcessing = false;
        return;
      }

      final objects = await _objectDetector.processImage(inputImage);

      DetectedObject? bestCard;
      if (objects.isNotEmpty) {
        final object = objects.first;
        if (_isCard(
          object.boundingBox,
          Size(image.width.toDouble(), image.height.toDouble()),
        )) {
          bestCard = object;
        }
      }

      if (mounted) {
        setState(() {
          _detectedObject = bestCard;
          final imageRotation =
              inputImage.metadata?.rotation ?? InputImageRotation.rotation0deg;
          final imageSize = inputImage.metadata?.size ?? Size.zero;

          _imageSize =
              (imageRotation == InputImageRotation.rotation90deg ||
                  imageRotation == InputImageRotation.rotation270deg)
              ? Size(imageSize.height, imageSize.width)
              : imageSize;
          _rotation = imageRotation;
        });
      }
    } catch (e) {
      debugPrint(e.toString());
    }

    _isProcessing = false;
  }

  int? _lastProcessTime;

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    final camera = _cameraController?.description;
    if (camera == null) return null;

    final sensorOrientation = camera.sensorOrientation;
    final imageRotation =
        InputImageRotationValue.fromRawValue(sensorOrientation) ??
        InputImageRotation.rotation0deg;
    final inputImageFormat =
        InputImageFormatValue.fromRawValue(image.format.raw) ??
        InputImageFormat.nv21;

    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: imageRotation,
        format: inputImageFormat,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  bool _isCard(Rect rect, Size imageSize) {
    final width = rect.width;
    final height = rect.height;

    // 1. Vertical Orientation Check
    if (width > height) return false;

    // 2. Aspect Ratio Check (Relaxed for faster/proper detection)
    final ratio = width / height;
    if (ratio < 0.62 || ratio > 0.82) return false;

    // 3. Minimum Size Check (Accepts cards that are "big" in frame)
    if (width < 120 || height < 180) return false;

    // 4. Center Position Check (More generous for instant detection)
    final centerX = imageSize.width / 2;
    final centerY = imageSize.height / 2;
    final objectCenterX = rect.center.dx;
    final objectCenterY = rect.center.dy;

    final dx = (objectCenterX - centerX).abs();
    final dy = (objectCenterY - centerY).abs();

    if (dx > 200 || dy > 200) return false;

    return true;
  }

  /// Camera2 on Android requires the image stream to stop before takePicture.
  Future<void> _stopImageStreamSafely() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    if (!controller.value.isStreamingImages) return;

    try {
      await controller.stopImageStream();
      // Let the capture session close before still capture / restart.
      await Future<void>.delayed(const Duration(milliseconds: 250));
    } catch (e) {
      debugPrint('Stop stream error: $e');
    }
  }

  Future<void> _captureImage() async {
    if (!_isDeviceLevel) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please hold the phone flat/level")),
      );
      return;
    }

    if (_isCapturing ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized) {
      return;
    }

    if (_detectedObject == null || _imageSize == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Image not detected. Please try again.'),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }

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
          !_cameraController!.value.isInitialized) {
        return;
      }

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

      if (mounted) {
        await _resumeStream();
      }
    } catch (e) {
      debugPrint("Capture error: $e");
      if (mounted) await _resumeStream();
    }
  }

  Future<void> _resumeStream() async {
    if (!mounted || _isResumingStream) return;

    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      if (mounted) {
        setState(() {
          _isCapturing = false;
          _detectedObject = null;
        });
      }
      return;
    }

    if (controller.value.isStreamingImages) {
      if (mounted) {
        setState(() {
          _isCapturing = false;
        });
      }
      return;
    }

    _isResumingStream = true;
    try {
      if (mounted) {
        setState(() {
          _isCapturing = false;
          _detectedObject = null;
        });
      }

      await controller.setFlashMode(FlashMode.off);
      await Future<void>.delayed(const Duration(milliseconds: 250));

      if (!mounted || !controller.value.isInitialized) return;

      await controller.startImageStream(_processCameraImage);
    } catch (e) {
      debugPrint('Resume stream error: $e');
      await _reinitializeCamera();
    } finally {
      _isResumingStream = false;
    }
  }

  Future<void> _reinitializeCamera() async {
    final oldController = _cameraController;
    _cameraController = null;

    try {
      if (oldController != null) {
        if (oldController.value.isStreamingImages) {
          await oldController.stopImageStream();
        }
        await oldController.dispose();
      }
    } catch (e) {
      debugPrint('Dispose camera error: $e');
    }

    if (!mounted) return;

    try {
      final cameras = await availableCameras();
      final backCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
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
      await _cameraController!.startImageStream(_processCameraImage);

      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Reinitialize camera error: $e');
    }
  }

  @override
  void dispose() {
    _accelerometerSubscription?.cancel();
    final controller = _cameraController;
    if (controller != null) {
      if (controller.value.isStreamingImages) {
        controller.stopImageStream().catchError((_) {});
      }
      controller.dispose();
    }
    _objectDetector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final previewAspectRatio = 1 / _cameraController!.value.aspectRatio;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: previewAspectRatio,
              child: CameraPreview(_cameraController!),
            ),
          ),

          if (_detectedObject != null &&
              _imageSize != null &&
              _rotation != null)
            IgnorePointer(
              child: Center(
                child: AspectRatio(
                  aspectRatio: previewAspectRatio,
                  child: CustomPaint(
                    painter: ObjectDetectorPainter(
                      [_detectedObject!],
                      _imageSize!,
                      _rotation!,
                      _cameraController!.description.lensDirection,
                    ),
                  ),
                ),
              ),
            ),

          // Card placement guide (grey scope + frame)
          if (!_isCapturing)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: CardGuideOverlayPainter(isLevel: _isDeviceLevel),
                ),
              ),
            ),

          // Spirit level bars — top (horizontal) & left (vertical), like reference UI
          if (!_isCapturing && _showSpiritLevel) ...[
            Positioned(
              top: MediaQuery.of(context).padding.top + 72,
              left: 0,
              right: 0,
              child: Center(
                child: SpiritLevelBar(
                  axis: SpiritLevelAxis.horizontal,
                  isLevel: _isHorizontalLevel,
                  tiltDegrees: _rollDeg,
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
                  isLevel: _isVerticalLevel,
                  tiltDegrees: _pitchDeg,
                ),
              ),
            ),
          ],

          // Status chip when not level
          if (!_isCapturing && !_isDeviceLevel)
            Positioned(
              top: MediaQuery.of(context).padding.top + 16,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Text(
                    'HOLD PHONE FLAT',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ),

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
                        backgroundColor: _isDeviceLevel
                            ? Colors.white
                            : Colors.grey,
                        child: Icon(
                          Icons.camera_alt,
                          color: _isDeviceLevel
                              ? Colors.black
                              : Colors.white54,
                          size: 28,
                        ),
                      ),
                const Spacer(),
                Material(
                  color: Colors.black.withValues(alpha: 0.45),
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
}

enum SpiritLevelAxis { horizontal, vertical }

/// Top / left spirit-level bar with moving dot (reference scanner UI).
class SpiritLevelBar extends StatelessWidget {
  final SpiritLevelAxis axis;
  final bool isLevel;
  final double tiltDegrees;

  const SpiritLevelBar({
    super.key,
    required this.axis,
    required this.isLevel,
    required this.tiltDegrees,
  });

  static const double _barThickness = 20;
  static const double _horizontalLength = 300;
  static const double _verticalLength = 260;

  @override
  Widget build(BuildContext context) {
    final isHorizontal = axis == SpiritLevelAxis.horizontal;
    final size = isHorizontal
        ? const Size(_horizontalLength, _barThickness)
        : const Size(_barThickness, _verticalLength);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: size.width,
      height: size.height,
      child: CustomPaint(
        painter: SpiritLevelBarPainter(
          isHorizontal: isHorizontal,
          isLevel: isLevel,
          normalizedOffset: (tiltDegrees / 15.0).clamp(-1.0, 1.0),
        ),
      ),
    );
  }
}

class SpiritLevelBarPainter extends CustomPainter {
  final bool isHorizontal;
  final bool isLevel;

  /// -1.0 -> left/top
  ///  0.0 -> center
  ///  1.0 -> right/bottom
  final double normalizedOffset;

  SpiritLevelBarPainter({
    required this.isHorizontal,
    required this.isLevel,
    required this.normalizedOffset,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final barRect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(size.height),
    );

    // ===== BACKGROUND BAR =====
    final bgPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          const Color(0x8838FF72),
          const Color(0x5525D366),
        ],
      ).createShader(Offset.zero & size);

    canvas.drawRRect(barRect, bgPaint);

    // ===== CENTER MARKERS =====
    final markerPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2;

    if (isHorizontal) {
      final centerX = size.width / 2;

      canvas.drawLine(
        Offset(centerX - 26, 0),
        Offset(centerX - 26, size.height),
        markerPaint,
      );

      canvas.drawLine(
        Offset(centerX + 26, 0),
        Offset(centerX + 26, size.height),
        markerPaint,
      );
    } else {
      final centerY = size.height / 2;

      canvas.drawLine(
        Offset(0, centerY - 26),
        Offset(size.width, centerY - 26),
        markerPaint,
      );

      canvas.drawLine(
        Offset(0, centerY + 26),
        Offset(size.width, centerY + 26),
        markerPaint,
      );
    }

    // ===== BALL POSITION =====
    final t = ((normalizedOffset + 1) / 2).clamp(0.0, 1.0);

    final bubbleCenter = isHorizontal
        ? Offset(t * size.width, size.height / 2)
        : Offset(size.width / 2, t * size.height);

    // ===== GLOW =====
    canvas.drawCircle(
      bubbleCenter,
      14,
      Paint()
        ..color = (isLevel
            ? const Color(0xFF32FF32)
            : Colors.orangeAccent)
            .withOpacity(0.35)
        ..maskFilter = const MaskFilter.blur(
          BlurStyle.normal,
          10,
        ),
    );

    // ===== MAIN BALL =====
    final bubblePaint = Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.white,
          isLevel
              ? const Color(0xFF32FF32)
              : Colors.orangeAccent,
        ],
      ).createShader(
        Rect.fromCircle(center: bubbleCenter, radius: 12),
      );

    canvas.drawCircle(
      bubbleCenter,
      12,
      bubblePaint,
    );

    // ===== SMALL HIGHLIGHT =====
    canvas.drawCircle(
      bubbleCenter.translate(-3, -3),
      3,
      Paint()..color = Colors.white.withOpacity(0.9),
    );
  }

  @override
  bool shouldRepaint(covariant SpiritLevelBarPainter oldDelegate) {
    return oldDelegate.normalizedOffset != normalizedOffset ||
        oldDelegate.isLevel != isLevel ||
        oldDelegate.isHorizontal != isHorizontal;
  }
}

/// Grey scope + card frame in the center of the camera view.
class CardGuideOverlayPainter extends CustomPainter {
  final bool isLevel;

  const CardGuideOverlayPainter({required this.isLevel});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final activeColor =
        isLevel ? const Color(0xC572EA87) : const Color(0x7CF8766D);

    final cardHeight = size.height * 0.56;
    final cardWidth = cardHeight * 0.72;
    final cardRect = Rect.fromCenter(
      center: center,
      width: cardWidth,
      height: cardHeight,
    );

    final dimPath = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(RRect.fromRectAndRadius(cardRect, const Radius.circular(10)))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(
      dimPath,
      Paint()..color = Colors.black.withValues(alpha: 0.4),
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(cardRect, const Radius.circular(10)),
      Paint()
        ..color = activeColor.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    _drawCornerBrackets(canvas, cardRect, activeColor);
  }

  void _drawCornerBrackets(Canvas canvas, Rect rect, Color color) {
    const len = 20.0;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(len, 0), paint);
    canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(0, len), paint);
    canvas.drawLine(rect.topRight, rect.topRight + const Offset(-len, 0), paint);
    canvas.drawLine(rect.topRight, rect.topRight + const Offset(0, len), paint);
    canvas.drawLine(
      rect.bottomLeft,
      rect.bottomLeft + const Offset(len, 0),
      paint,
    );
    canvas.drawLine(
      rect.bottomLeft,
      rect.bottomLeft + const Offset(0, -len),
      paint,
    );
    canvas.drawLine(
      rect.bottomRight,
      rect.bottomRight + const Offset(-len, 0),
      paint,
    );
    canvas.drawLine(
      rect.bottomRight,
      rect.bottomRight + const Offset(0, -len),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CardGuideOverlayPainter oldDelegate) =>
      oldDelegate.isLevel != isLevel;
}

/// Guide boxes in image pixel space for read-only result display.
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

  /// Green inner box = [outer] inset by exactly [inset] on all sides (scaled if needed).
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
      final fallback = inset.clamp(0.0, outer.shortestSide / 4);
      left = outer.left + fallback;
      top = outer.top + fallback;
      right = outer.right - fallback;
      bottom = outer.bottom - fallback;
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
    final outer = detection.outerBox ??
        Rect.fromLTWH(0, 0, imageSize.width, imageSize.height);
    return CardOverlaySnapshot(
      coordinateSize: imageSize,
      outerGuideRect: outer,
      innerGuideRect: innerRectFromOuter(outer, imageSize),
    );
  }

  static Rect _boundsFromCorners(List<Offset> corners) {
    var minX = corners.first.dx;
    var maxX = corners.first.dx;
    var minY = corners.first.dy;
    var maxY = corners.first.dy;
    for (final p in corners) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }
}

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

  /// Green inner (main) box: this many pixels inside the purple outer box.
  static const double _guideInnerInset = 20.0;

  /// Purple outer box: fixed padding around the card on first placement (smaller/tighter).
  static const double _guideOuterInset = -15.0;
  static const double _minGap = 12.0;
  static const double _cropPaddingFactor = 0.15;

  @override
  void initState() {
    super.initState();
    _initializePreviewState();
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
  }) async {
    if (mounted) setState(() => _isUploading = true);

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

      final directory = await getTemporaryDirectory();
      final path =
          '${directory.path}/crop_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final croppedFile = File(path);
      await croppedFile.writeAsBytes(img.encodeJpg(cropped));

      if (updatePreview && mounted) {
        setState(() {
          _croppedPath = path;
        });
      }
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
      debugPrint("Crop error: $e");
      return null;
    } finally {
      if (mounted) setState(() => _isUploading = false);
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
      final scaleX = imageSize.width / _previewCoordinateSize!.width;
      final scaleY = imageSize.height / _previewCoordinateSize!.height;
      final outer = Rect.fromLTRB(
        _guideOuterRect!.left * scaleX,
        _guideOuterRect!.top * scaleY,
        _guideOuterRect!.right * scaleX,
        _guideOuterRect!.bottom * scaleY,
      );
      return CardOverlaySnapshot(
        coordinateSize: imageSize,
        outerGuideRect: outer,
        innerGuideRect: CardOverlaySnapshot.innerRectFromOuter(
          outer,
          imageSize,
          insetScaleX: scaleX,
          insetScaleY: scaleY,
        ),
      );
    }

    if (_detectedRectOriginal != null) {
      final detected = _detectedRectOriginal!;
      final outer = detected.inflate(24);
      return CardOverlaySnapshot(
        coordinateSize: imageSize,
        outerGuideRect: outer,
        innerGuideRect: CardOverlaySnapshot.innerRectFromOuter(outer, imageSize),
      );
    }

    return null;
  }

  Future<void> _onCheckPressed() async {
    setState(() => _isUploading = true);

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

      final response = await _uploadImage(imageToUpload);
      if (!mounted) return;

      final detection = ApiCardDetection.fromResponse(response);
      final apiMessage = response['message']?.toString();

      if (response['success'] == true && detection.isDetected) {
        if (overlaySnapshot == null) {
          final imageSize = await _getImageSize(imageToUpload);
          if (detection.hasGeometry) {
            overlaySnapshot =
                CardOverlaySnapshot.fromApi(detection, imageSize);
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
          : 'Not a Pokémon card';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(failureMessage),
          duration: const Duration(seconds: 3),
        ),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      debugPrint("API Error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<Map<String, dynamic>> _uploadImage(File imageFile) async {
    var request = http.MultipartRequest('POST', Uri.parse(kDetectCardEndpoint));
    if (kHfApiToken.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $kHfApiToken';
    }
    request.files.add(
      await http.MultipartFile.fromPath(
        'file',
        imageFile.path,
        contentType: MediaType('image', 'jpeg'),
      ),
    );
    var response = await http.Response.fromStream(await request.send());

    debugPrint("API Response Body: ${response.body}");

    if (response.statusCode == 200) {
      final decoded = json.decode(response.body);
      if (decoded is Map<String, dynamic>) return decoded;
      return {"success": false, "message": "Invalid response format"};
    }
    return {
      "success": false,
      "message": "Server error: ${response.statusCode}",
    };
  }

  /// Places guide boxes around the detected card inside the cropped image.
  /// Uses cropped pixel space only: maps detection offset within the first-crop
  /// region, then scales to [croppedSize].
  void _setGuideRectsAroundCard({
    required Rect detectedRect,
    required Rect firstCropRect,
    required Size croppedSize,
  }) {
    final cardInCropLocal = Rect.fromLTRB(
      detectedRect.left - firstCropRect.left,
      detectedRect.top - firstCropRect.top,
      detectedRect.right - firstCropRect.left,
      detectedRect.bottom - firstCropRect.top,
    );

    final scaleX = croppedSize.width / firstCropRect.width;
    final scaleY = croppedSize.height / firstCropRect.height;

    final cardInCrop = Rect.fromLTRB(
      cardInCropLocal.left * scaleX,
      cardInCropLocal.top * scaleY,
      cardInCropLocal.right * scaleX,
      cardInCropLocal.bottom * scaleY,
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

  /// Inner guide = outer inset by exactly 20px on all sides.
  Rect _innerRectFromOuter(Rect outer, Size bounds) {
    return CardOverlaySnapshot.innerRectFromOuter(outer, bounds);
  }

  void _onOuterGuideChanged(Rect outer) {
    final bounds = _previewCoordinateSize;
    if (bounds == null) return;

    final minOuterSize = _minGap;
    final clamped = Rect.fromLTRB(
      outer.left.clamp(0.0, bounds.width - minOuterSize),
      outer.top.clamp(0.0, bounds.height - minOuterSize),
      outer.right.clamp(outer.left + minOuterSize, bounds.width),
      outer.bottom.clamp(outer.top + minOuterSize, bounds.height),
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

      // Before first crop use ML rect as hint
      final hint = _isFirstCropApplied
          ? null
          : _detectedRectOriginal;

      final result = await CardCornerDetector.detectFromFile(
        File(sourcePath),
        searchRegion: hint,
        outerPadding: _isFirstCropApplied
            ? 0
            : _guideOuterInset.abs(),
      );

      if (!mounted) return;

      // =========================
      // FIRST AUTO SCAN
      // =========================
      if (!_isFirstCropApplied) {
        if (!_consumeOpenCvResult(result, onValid: () {})) return;
        final photoSize =
            _previewCoordinateSize ??
                await _getImageSize(File(widget.imagePath));

        if (!mounted) return;

        final detectedBounds =
        _boundsFromCorners(result.corners);

        setState(() {
          _detectedRectOriginal = detectedBounds;

          // SAVE REAL CARD POLYGON
          _opencvCorners = result.corners;

          _previewCoordinateSize = photoSize;
        });

        // FIRST CROP
        await _handleFirstCrop();

        if (!mounted || !_isFirstCropApplied) return;

        // REFINE ON CROPPED IMAGE
        final refined =
        await CardCornerDetector.detectFromFile(
          File(_croppedPath!),
          outerPadding: _guideInnerInset,
        );

        if (!mounted) return;

        if (!_consumeOpenCvResult(
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
        )) {
          return;
        }
      }

      // =========================
      // AFTER FIRST CROP
      // =========================
      else {
        if (!_consumeOpenCvResult(
          result,
          onValid: () {
            final bounds = _previewCoordinateSize;
            if (bounds == null) return;

            final resultBounds = _boundsFromCorners(result.corners);

            setState(() {
              _guideOuterRect = resultBounds;
              _guideInnerRect = _innerRectFromOuter(resultBounds, bounds);
              _opencvCorners = result.corners;
            });
          },
        )) {
          return;
        }
      }
    } catch (e) {
      debugPrint('Auto Scan Error: $e');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Auto scan failed'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isAutoScanning = false);
      }
    }
  }
  Rect _boundsFromCorners(List<Offset> corners) {
    double minX = corners.first.dx;
    double maxX = corners.first.dx;
    double minY = corners.first.dy;
    double maxY = corners.first.dy;

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

    final paddingX = detectedRect.width * _cropPaddingFactor;
    final paddingY = detectedRect.height * _cropPaddingFactor;

    final firstCropRect = Rect.fromLTRB(
      math.max(0, detectedRect.left - paddingX),
      math.max(0, detectedRect.top - paddingY),
      math.min(previewCoordinateSize.width, detectedRect.right + paddingX),
      math.min(previewCoordinateSize.height, detectedRect.bottom + paddingY),
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
    final outerGuide = _guideOuterRect!;
    final innerGuide = _guideInnerRect!;

    setState(() {
      _isFirstCropApplied = true;
      _firstCropRect = firstCropRect;
      _previewCoordinateSize = cropped.croppedSize;
      _initialOuterGuide = outerGuide;
      _initialInnerGuide = innerGuide;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Preview"),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Column(
        children: [
          Expanded(
            child:
                _isFirstCropApplied &&
                    _croppedPath != null &&
                    _guideOuterRect != null &&
                    _guideInnerRect != null &&
                    _previewCoordinateSize != null
                ? Center(
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
                              onInnerChanged: (rect) =>
                                  setState(() => _guideInnerRect = rect),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                : Stack(
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
                            builder: (context, constraints) {
                              return FutureBuilder<Size>(
                                future: _getImageSize(File(widget.imagePath)),
                                builder: (context, snapshot) {
                                  if (!snapshot.hasData)
                                    return const SizedBox.shrink();
                                  final displayRect = _getDisplayedImageRect(
                                    containerSize: Size(
                                      constraints.maxWidth,
                                      constraints.maxHeight,
                                    ),
                                    imageSize: snapshot.data!,
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
                  ),
          ),
          Container(
            padding: const EdgeInsets.all(24.0),
            decoration: const BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: _isUploading || _isAutoScanning
                ? const Center(child: CircularProgressIndicator())
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.pop(context),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(0, 48),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                side: const BorderSide(
                                  color: Colors.white,
                                  width: 2,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: _previewActionLabel(
                                'Retake',
                                color: Colors.white,
                              ),
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
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                backgroundColor: const Color(0xFF4A80F0),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: _previewActionLabel(
                                _isFirstCropApplied ? 'ML Crop' : 'ML Crop',
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _onCheckPressed,
                              style: ElevatedButton.styleFrom(
                                minimumSize: const Size(0, 48),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                backgroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: _previewActionLabel(
                                _isFirstCropApplied ? 'Api Check' : 'Api Check',
                                color: Colors.black,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _handleAutoScan,
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 48),
                            side: const BorderSide(
                              color: Colors.white,
                              width: 2,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          icon: const Icon(
                            Icons.document_scanner_outlined,
                            color: Colors.white,
                            size: 20,
                          ),
                          label: _previewActionLabel(
                            'OpenCV Auto Scan',
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
          if (_cornerValidation != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: _cornerValidation!.isValid
                      ? const Color(0xFF1A3324)
                      : const Color(0xFF3A1A1A),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _cornerValidation!.isValid
                        ? const Color(0xFF3DDC84)
                        : const Color(0xFFFF5252),
                    width: 1.5,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _cornerValidation!.isValid
                          ? 'OpenCV corners valid'
                          : 'OpenCV corners invalid — rescan',
                      style: TextStyle(
                        color: _cornerValidation!.isValid
                            ? const Color(0xFF3DDC84)
                            : const Color(0xFFFF5252),
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Max X/Y defect: '
                      '${_cornerValidation!.maxAxisDefectPx.toStringAsFixed(1)} px '
                      '(limit ${CardCornerValidator.maxDefect.toInt()}) · Max angle: '
                      '${_cornerValidation!.maxAngleDefectDeg.toStringAsFixed(1)}° '
                      '(limit ${CardCornerValidator.maxDefect.toInt()})',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_isFirstCropApplied &&
              _croppedPath != null &&
              _guideOuterRect != null &&
              _guideInnerRect != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: _buildMetricCard(
                      'Horizontal',
                      _formatSplitValue(
                        _guideInnerRect!.left - _guideOuterRect!.left,
                        _guideOuterRect!.right - _guideInnerRect!.right,
                      ),
                      icon: Icons.swap_horiz,
                      subtitle: 'Left · Right',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildMetricCard(
                      'Vertical',
                      _formatSplitValue(
                        _guideInnerRect!.top - _guideOuterRect!.top,
                        _guideOuterRect!.bottom - _guideInnerRect!.bottom,
                      ),
                      icon: Icons.swap_vert,
                      subtitle: 'Top · Bottom',
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Rect _getDisplayedImageRect({
    required Size containerSize,
    required Size imageSize,
  }) {
    final scale = math.min(
      containerSize.width / imageSize.width,
      containerSize.height / imageSize.height,
    );
    final width = imageSize.width * scale;
    final height = imageSize.height * scale;
    return Rect.fromLTWH(
      (containerSize.width - width) / 2,
      (containerSize.height - height) / 2,
      width,
      height,
    );
  }

  Widget _previewActionLabel(String text, {required Color color}) {
    return Text(
      text,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: color,
        fontSize: 14,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.2,
      ),
    );
  }

  Widget _buildMetricCard(
    String title,
    String value, {
    IconData? icon,
    String? subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, color: const Color(0xFF7B61FF), size: 28),
            const SizedBox(width: 12),
          ],
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
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
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
                ],
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

  String _formatSplitValue(double first, double second) {
    final total = first + second;
    if (total <= 0) return "50.0/50.0";
    final firstPercent = (first / total) * 100;
    final secondPercent = (second / total) * 100;
    return "${firstPercent.toStringAsFixed(1)}/${secondPercent.toStringAsFixed(1)}";
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
    final scaleX = imageBounds.width / coordinateSize.width;
    final scaleY = imageBounds.height / coordinateSize.height;
    final displayRect = Rect.fromLTRB(
      imageBounds.left + (detectedRect.left * scaleX),
      imageBounds.top + (detectedRect.top * scaleY),
      imageBounds.left + (detectedRect.right * scaleX),
      imageBounds.top + (detectedRect.bottom * scaleY),
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
  bool shouldRepaint(covariant CropOverlayPainter oldDelegate) =>
      oldDelegate.detectedRect != detectedRect;
}

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

  Offset _toDisplayPoint(Offset point) {
    final scaleX = imageBounds.width / coordinateSize.width;
    final scaleY = imageBounds.height / coordinateSize.height;
    return Offset(
      imageBounds.left + (point.dx * scaleX),
      imageBounds.top + (point.dy * scaleY),
    );
  }

  double _deltaToCoordinateX(double delta) =>
      delta * coordinateSize.width / imageBounds.width;

  double _deltaToCoordinateY(double delta) =>
      delta * coordinateSize.height / imageBounds.height;

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
        // Corner handles for outer guide
        _buildCornerHandle(
          point: _toDisplayPoint(
            Offset(outerGuideRect.left, outerGuideRect.top),
          ),
          color: const Color(0xFF7B61FF),
          onDrag: (details) {
            final dx = _deltaToCoordinateX(details.delta.dx);
            final dy = _deltaToCoordinateY(details.delta.dy);
            final nextLeft = (outerGuideRect.left + dx).clamp(
              0.0,
              outerGuideRect.right - _ConfirmationScreenState._minGap,
            );
            final nextTop = (outerGuideRect.top + dy).clamp(
              0.0,
              outerGuideRect.bottom - _ConfirmationScreenState._minGap,
            );
            onOuterChanged(
              Rect.fromLTRB(
                nextLeft,
                nextTop,
                outerGuideRect.right,
                outerGuideRect.bottom,
              ),
            );
          },
        ),
        _buildCornerHandle(
          point: _toDisplayPoint(
            Offset(outerGuideRect.right, outerGuideRect.top),
          ),
          color: const Color(0xFF7B61FF),
          onDrag: (details) {
            final dx = _deltaToCoordinateX(details.delta.dx);
            final dy = _deltaToCoordinateY(details.delta.dy);
            final nextRight = (outerGuideRect.right + dx).clamp(
              outerGuideRect.left + _ConfirmationScreenState._minGap,
              coordinateSize.width,
            );
            final nextTop = (outerGuideRect.top + dy).clamp(
              0.0,
              outerGuideRect.bottom - _ConfirmationScreenState._minGap,
            );
            onOuterChanged(
              Rect.fromLTRB(
                outerGuideRect.left,
                nextTop,
                nextRight,
                outerGuideRect.bottom,
              ),
            );
          },
        ),
        _buildCornerHandle(
          point: _toDisplayPoint(
            Offset(outerGuideRect.right, outerGuideRect.bottom),
          ),
          color: const Color(0xFF7B61FF),
          onDrag: (details) {
            final dx = _deltaToCoordinateX(details.delta.dx);
            final dy = _deltaToCoordinateY(details.delta.dy);
            final nextRight = (outerGuideRect.right + dx).clamp(
              outerGuideRect.left + _ConfirmationScreenState._minGap,
              coordinateSize.width,
            );
            final nextBottom = (outerGuideRect.bottom + dy).clamp(
              outerGuideRect.top + _ConfirmationScreenState._minGap,
              coordinateSize.height,
            );
            onOuterChanged(
              Rect.fromLTRB(
                outerGuideRect.left,
                outerGuideRect.top,
                nextRight,
                nextBottom,
              ),
            );
          },
        ),
        _buildCornerHandle(
          point: _toDisplayPoint(
            Offset(outerGuideRect.left, outerGuideRect.bottom),
          ),
          color: const Color(0xFF7B61FF),
          onDrag: (details) {
            final dx = _deltaToCoordinateX(details.delta.dx);
            final dy = _deltaToCoordinateY(details.delta.dy);
            final nextLeft = (outerGuideRect.left + dx).clamp(
              0.0,
              outerGuideRect.right - _ConfirmationScreenState._minGap,
            );
            final nextBottom = (outerGuideRect.bottom + dy).clamp(
              outerGuideRect.top + _ConfirmationScreenState._minGap,
              coordinateSize.height,
            );
            onOuterChanged(
              Rect.fromLTRB(
                nextLeft,
                outerGuideRect.top,
                outerGuideRect.right,
                nextBottom,
              ),
            );
          },
        ),
        _buildHandle(
          point: _toDisplayPoint(
            Offset(
              (outerGuideRect.left + outerGuideRect.right) / 2,
              outerGuideRect.top,
            ),
          ),
          icon: Icons.keyboard_arrow_up,
          color: const Color(0xFF7B61FF),
          onDrag: (details) {
            final nextTop =
                (outerGuideRect.top + _deltaToCoordinateY(details.delta.dy))
                    .clamp(
                      0.0,
                      outerGuideRect.bottom -
                          _ConfirmationScreenState._minGap -
                          _ConfirmationScreenState._guideInnerInset * 2,
                    );
            onOuterChanged(
              Rect.fromLTRB(
                outerGuideRect.left,
                nextTop,
                outerGuideRect.right,
                outerGuideRect.bottom,
              ),
            );
          },
        ),
        _buildHandle(
          point: _toDisplayPoint(
            Offset(
              (outerGuideRect.left + outerGuideRect.right) / 2,
              outerGuideRect.bottom,
            ),
          ),
          icon: Icons.keyboard_arrow_down,
          color: const Color(0xFF7B61FF),
          onDrag: (details) {
            final minBottom =
                outerGuideRect.top +
                _ConfirmationScreenState._minGap +
                _ConfirmationScreenState._guideInnerInset * 2;
            final nextBottom =
                (outerGuideRect.bottom + _deltaToCoordinateY(details.delta.dy))
                    .clamp(minBottom, coordinateSize.height);
            onOuterChanged(
              Rect.fromLTRB(
                outerGuideRect.left,
                outerGuideRect.top,
                outerGuideRect.right,
                nextBottom,
              ),
            );
          },
        ),
        _buildHandle(
          point: _toDisplayPoint(
            Offset(
              outerGuideRect.left,
              (outerGuideRect.top + outerGuideRect.bottom) / 2,
            ),
          ),
          icon: Icons.keyboard_arrow_left,
          color: const Color(0xFF7B61FF),
          onDrag: (details) {
            final maxLeft =
                outerGuideRect.right -
                _ConfirmationScreenState._minGap -
                _ConfirmationScreenState._guideInnerInset * 2;
            final nextLeft =
                (outerGuideRect.left + _deltaToCoordinateX(details.delta.dx))
                    .clamp(0.0, maxLeft);
            onOuterChanged(
              Rect.fromLTRB(
                nextLeft,
                outerGuideRect.top,
                outerGuideRect.right,
                outerGuideRect.bottom,
              ),
            );
          },
        ),
        _buildHandle(
          point: _toDisplayPoint(
            Offset(
              outerGuideRect.right,
              (outerGuideRect.top + outerGuideRect.bottom) / 2,
            ),
          ),
          icon: Icons.keyboard_arrow_right,
          color: const Color(0xFF7B61FF),
          onDrag: (details) {
            final minRight =
                outerGuideRect.left +
                _ConfirmationScreenState._minGap +
                _ConfirmationScreenState._guideInnerInset * 2;
            final nextRight =
                (outerGuideRect.right + _deltaToCoordinateX(details.delta.dx))
                    .clamp(minRight, coordinateSize.width);
            onOuterChanged(
              Rect.fromLTRB(
                outerGuideRect.left,
                outerGuideRect.top,
                nextRight,
                outerGuideRect.bottom,
              ),
            );
          },
        ),
        _buildHandle(
          point: _toDisplayPoint(
            Offset(
              (innerGuideRect.left + innerGuideRect.right) / 2,
              innerGuideRect.top,
            ),
          ),
          icon: Icons.keyboard_arrow_down,
          color: const Color(0xFF3DDC84),
          onDrag: (details) {
            final nextTop =
                (innerGuideRect.top + _deltaToCoordinateY(details.delta.dy))
                    .clamp(
                      outerGuideRect.top + _ConfirmationScreenState._minGap,
                      innerGuideRect.bottom - _ConfirmationScreenState._minGap,
                    );
            onInnerChanged(
              Rect.fromLTRB(
                innerGuideRect.left,
                nextTop,
                innerGuideRect.right,
                innerGuideRect.bottom,
              ),
            );
          },
        ),
        _buildHandle(
          point: _toDisplayPoint(
            Offset(
              (innerGuideRect.left + innerGuideRect.right) / 2,
              innerGuideRect.bottom,
            ),
          ),
          icon: Icons.keyboard_arrow_up,
          color: const Color(0xFF3DDC84),
          onDrag: (details) {
            final nextBottom =
                (innerGuideRect.bottom + _deltaToCoordinateY(details.delta.dy))
                    .clamp(
                      innerGuideRect.top + _ConfirmationScreenState._minGap,
                      outerGuideRect.bottom - _ConfirmationScreenState._minGap,
                    );
            onInnerChanged(
              Rect.fromLTRB(
                innerGuideRect.left,
                innerGuideRect.top,
                innerGuideRect.right,
                nextBottom,
              ),
            );
          },
        ),
        _buildHandle(
          point: _toDisplayPoint(
            Offset(
              innerGuideRect.left,
              (innerGuideRect.top + innerGuideRect.bottom) / 2,
            ),
          ),
          icon: Icons.keyboard_arrow_right,
          color: const Color(0xFF3DDC84),
          onDrag: (details) {
            final nextLeft =
                (innerGuideRect.left + _deltaToCoordinateX(details.delta.dx))
                    .clamp(
                      outerGuideRect.left + _ConfirmationScreenState._minGap,
                      innerGuideRect.right - _ConfirmationScreenState._minGap,
                    );
            onInnerChanged(
              Rect.fromLTRB(
                nextLeft,
                innerGuideRect.top,
                innerGuideRect.right,
                innerGuideRect.bottom,
              ),
            );
          },
        ),
        _buildHandle(
          point: _toDisplayPoint(
            Offset(
              innerGuideRect.right,
              (innerGuideRect.top + innerGuideRect.bottom) / 2,
            ),
          ),
          icon: Icons.keyboard_arrow_left,
          color: const Color(0xFF3DDC84),
          onDrag: (details) {
            final nextRight =
                (innerGuideRect.right + _deltaToCoordinateX(details.delta.dx))
                    .clamp(
                      innerGuideRect.left + _ConfirmationScreenState._minGap,
                      outerGuideRect.right - _ConfirmationScreenState._minGap,
                    );
            onInnerChanged(
              Rect.fromLTRB(
                innerGuideRect.left,
                innerGuideRect.top,
                nextRight,
                innerGuideRect.bottom,
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildHandle({
    required Offset point,
    required IconData icon,
    required Color color,
    required GestureDragUpdateCallback onDrag,
  }) {
    const size = 32.0;
    return Positioned(
      left: point.dx - size / 2,
      top: point.dy - size / 2,
      child: GestureDetector(
        onPanUpdate: onDrag,
        child: Container(
          width: size,
          height: size,
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

  Widget _buildCornerHandle({
    required Offset point,
    required Color color,
    required GestureDragUpdateCallback onDrag,
  }) {
    const size = 10.0;
    return Positioned(
      left: point.dx - size / 2,
      top: point.dy - size / 2,
      child: GestureDetector(
        onPanUpdate: onDrag,
        child: Container(
          width: size,
          height: size,
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

class GuideBoxesPainter extends CustomPainter {
  final Size coordinateSize;
  final Rect outerGuideRect;
  final Rect innerGuideRect;

  const GuideBoxesPainter({
    required this.coordinateSize,
    required this.outerGuideRect,
    required this.innerGuideRect,
  });

  Rect _scaleRect(Rect rect, Size size) {
    final scaleX = size.width / coordinateSize.width;
    final scaleY = size.height / coordinateSize.height;
    return Rect.fromLTRB(
      rect.left * scaleX,
      rect.top * scaleY,
      rect.right * scaleX,
      rect.bottom * scaleY,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final outer = _scaleRect(outerGuideRect, size);
    final inner = _scaleRect(innerGuideRect, size);

    final full = Path()..addRect(Offset.zero & size);
    final hole = Path()..addRect(outer);
    canvas.drawPath(
      Path.combine(PathOperation.difference, full, hole),
      Paint()..color = Colors.black.withValues(alpha: 0.45),
    );

    final band = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(outer)
      ..addRect(inner);
    canvas.save();
    canvas.clipPath(band);
    final hatch = Paint()
      ..color = const Color(0xFF4A80F0).withValues(alpha: 0.55)
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
  bool shouldRepaint(covariant GuideBoxesPainter oldDelegate) =>
      oldDelegate.outerGuideRect != outerGuideRect ||
      oldDelegate.innerGuideRect != innerGuideRect;
}

class ObjectDetectorPainter extends CustomPainter {
  final List<DetectedObject> objects;
  final Size imageSize;
  final InputImageRotation rotation;
  final CameraLensDirection lensDirection;

  ObjectDetectorPainter(
    this.objects,
    this.imageSize,
    this.rotation,
    this.lensDirection,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paintCorners = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.0
      ..color = Colors.greenAccent
      ..strokeCap = StrokeCap.round;
    final Paint paintFill = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.greenAccent.withAlpha(100);
    for (final object in objects) {
      final rect = _translateRect(
        object.boundingBox,
        imageSize,
        size,
        rotation,
        lensDirection,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(8)),
        paintFill,
      );
      const double cs = 25.0;
      final path = Path()
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
        ..lineTo(rect.left, rect.bottom - cs);
      canvas.drawPath(path, paintCorners);
      final dotPaint = Paint()..color = Colors.greenAccent;
      canvas.drawCircle(rect.topLeft, 6, dotPaint);
      canvas.drawCircle(rect.topRight, 6, dotPaint);
      canvas.drawCircle(rect.bottomLeft, 6, dotPaint);
      canvas.drawCircle(rect.bottomRight, 6, dotPaint);
    }
  }

  Rect _translateRect(
    Rect rect,
    Size imageSize,
    Size widgetSize,
    InputImageRotation rotation,
    CameraLensDirection lensDirection,
  ) {
    final scaleX = widgetSize.width / imageSize.width;
    final scaleY = widgetSize.height / imageSize.height;
    double left = rect.left * scaleX;
    double top = rect.top * scaleY;
    double right = rect.right * scaleX;
    double bottom = rect.bottom * scaleY;
    if (lensDirection == CameraLensDirection.front) {
      final tempLeft = left;
      left = widgetSize.width - right;
      right = widgetSize.width - tempLeft;
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  @override
  bool shouldRepaint(ObjectDetectorPainter oldDelegate) =>
      oldDelegate.objects != objects || oldDelegate.imageSize != imageSize;
}

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
    final message =
        apiResponse['message']?.toString() ?? 'Pokémon card detected';
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
            padding: const EdgeInsets.all(24.0),
            child: ElevatedButton(
              onPressed: () =>
                  Navigator.popUntil(context, (route) => route.isFirst),
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
    final cardName = rawName.contains('/')
        ? rawName.split('/').last
        : rawName;
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
                  child: _infoChip(
                    'Similarity',
                    '${(score * 100).toStringAsFixed(1)}%',
                  ),
                ),
                if (margin != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: _infoChip(
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

  Widget _infoChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF222222),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
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
}

/// Final card image with preview-style guide boxes (read-only).
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
      future: _getImageSize(File(imagePath)),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data == Size.zero) {
          return const Center(child: CircularProgressIndicator());
        }

        final imageSize = snapshot.data!;
        final baseOverlay = overlay ??
            (detection.hasGeometry
                ? CardOverlaySnapshot.fromApi(detection, imageSize)
                : _defaultOverlay(imageSize));
        final snapshotOverlay = baseOverlay.forResultDisplay();

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
                          coordinateSize: snapshotOverlay.coordinateSize,
                          outerGuideRect: snapshotOverlay.outerGuideRect,
                          innerGuideRect: snapshotOverlay.innerGuideRect,
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

  Future<Size> _getImageSize(File file) async {
    final bytes = await file.readAsBytes();
    final decoded = img.decodeImage(bytes);
    final image = decoded == null ? null : img.bakeOrientation(decoded);
    return image == null
        ? Size.zero
        : Size(image.width.toDouble(), image.height.toDouble());
  }
}
