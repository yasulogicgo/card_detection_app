import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'confirmation_screen.dart';

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

  DetectedObject? _detectedObject;
  Size? _imageSize;
  InputImageRotation? _rotation;

  // Sensor variables
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;
  double _tiltX = 0;
  double _tiltY = 0;
  bool _isDeviceLevel = false;

  @override
  void initState() {
    super.initState();
    _initialize();
    _startSensorTracking();
  }

  void _startSensorTracking() {
    _accelerometerSubscription = accelerometerEvents.listen((AccelerometerEvent event) {
      if (!mounted) return;

      double x = event.x;
      double y = event.y;
      double z = event.z;

      // Calculate the angle from the Z-axis (how "flat" the phone is)
      double tilt = math.acos(z / math.sqrt(x * x + y * y + z * z)) * (180 / math.pi);

      setState(() {
        _tiltX = x;
        _tiltY = y;
        // Consider level if tilt is within 10 degrees of being perfectly flat
        _isDeviceLevel = tilt < 10.0;
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
    await _cameraController!.lockCaptureOrientation(DeviceOrientation.portraitUp);

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
        if (_isCard(object.boundingBox, Size(image.width.toDouble(), image.height.toDouble()))) {
          bestCard = object;
        }
      }

      if (mounted) {
        setState(() {
          _detectedObject = bestCard;
          final imageRotation = inputImage.metadata?.rotation ?? InputImageRotation.rotation0deg;
          final imageSize = inputImage.metadata?.size ?? Size.zero;

          _imageSize = (imageRotation == InputImageRotation.rotation90deg ||
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
    final imageRotation = InputImageRotationValue.fromRawValue(sensorOrientation) ?? InputImageRotation.rotation0deg;
    final inputImageFormat = InputImageFormatValue.fromRawValue(image.format.raw) ?? InputImageFormat.nv21;

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

  Future<void> _captureImage() async {
    if (!_isDeviceLevel) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please hold the phone flat/level")),
      );
      return;
    }

    if (_isCapturing || _cameraController == null || !_cameraController!.value.isInitialized) return;

    final currentRect = _detectedObject?.boundingBox;
    final currentStreamSize = _imageSize;

    setState(() {
      _isCapturing = true;
      _detectedObject = null;
    });

    try {
      final XFile file = await _cameraController!.takePicture();
      await _cameraController!.stopImageStream();

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
        _resumeStream();
      }
    } catch (e) {
      debugPrint("Capture error: $e");
      _resumeStream();
    }
  }

  void _resumeStream() {
    if (mounted) {
      setState(() {
        _isCapturing = false;
        _detectedObject = null;
      });
      _cameraController?.setFlashMode(FlashMode.off); // Ensure flash is off on resume
      _cameraController?.startImageStream(_processCameraImage);
    }
  }

  @override
  void dispose() {
    _accelerometerSubscription?.cancel();
    _cameraController?.dispose();
    _objectDetector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
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

          if (_detectedObject != null && _imageSize != null && _rotation != null)
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

          // Stability / Level Indicator
          if (!_isCapturing)
            Positioned(
              top: 60,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: _isDeviceLevel ? Colors.green.withOpacity(0.8) : Colors.red.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _isDeviceLevel ? Icons.check_circle : Icons.warning,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _isDeviceLevel ? "DEVICE LEVEL" : "HOLD PHONE FLAT",
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Bubble Level Visual
          if (!_isCapturing)
            Center(
              child: Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white24, width: 2),
                  shape: BoxShape.circle,
                ),
                child: Stack(
                  children: [
                    Center(
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(color: Colors.white24, shape: BoxShape.circle),
                      ),
                    ),
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 50),
                      left: 45 + (_tiltX * 4),
                      top: 45 + (_tiltY * 4),
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: _isDeviceLevel ? Colors.green : Colors.red,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: _isCapturing
                  ? const CircularProgressIndicator(color: Colors.white)
                  : FloatingActionButton(
                      onPressed: _captureImage,
                      backgroundColor: _isDeviceLevel ? Colors.white : Colors.grey,
                      child: Icon(
                        Icons.camera_alt,
                        color: _isDeviceLevel ? Colors.black : Colors.white54,
                        size: 28
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class ObjectDetectorPainter extends CustomPainter {
  final List<DetectedObject> objects;
  final Size imageSize;
  final InputImageRotation rotation;
  final CameraLensDirection lensDirection;
  ObjectDetectorPainter(this.objects, this.imageSize, this.rotation, this.lensDirection);
  @override
  void paint(Canvas canvas, Size size) {
    final Paint paintCorners = Paint()..style = PaintingStyle.stroke..strokeWidth = 5.0..color = Colors.greenAccent..strokeCap = StrokeCap.round;
    final Paint paintFill = Paint()..style = PaintingStyle.fill..color = Colors.greenAccent.withAlpha(100);
    for (final object in objects) {
      final rect = _translateRect(object.boundingBox, imageSize, size, rotation, lensDirection);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(8)), paintFill);
      const double cs = 25.0;
      final path = Path()..moveTo(rect.left, rect.top + cs)..lineTo(rect.left, rect.top)..lineTo(rect.left + cs, rect.top)..moveTo(rect.right - cs, rect.top)..lineTo(rect.right, rect.top)..lineTo(rect.right, rect.top + cs)..moveTo(rect.right, rect.bottom - cs)..lineTo(rect.right, rect.bottom)..lineTo(rect.right - cs, rect.bottom)..moveTo(rect.left + cs, rect.bottom)..lineTo(rect.left, rect.bottom)..lineTo(rect.left, rect.bottom - cs);
      canvas.drawPath(path, paintCorners);
      final dotPaint = Paint()..color = Colors.greenAccent;
      canvas.drawCircle(rect.topLeft, 6, dotPaint);
      canvas.drawCircle(rect.topRight, 6, dotPaint);
      canvas.drawCircle(rect.bottomLeft, 6, dotPaint);
      canvas.drawCircle(rect.bottomRight, 6, dotPaint);
    }
  }
  Rect _translateRect(Rect rect, Size imageSize, Size widgetSize, InputImageRotation rotation, CameraLensDirection lensDirection) {
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
  bool shouldRepaint(ObjectDetectorPainter oldDelegate) => oldDelegate.objects != objects || oldDelegate.imageSize != imageSize;
}
