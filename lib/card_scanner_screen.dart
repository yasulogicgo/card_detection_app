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
import 'package:sensors_plus/sensors_plus.dart';

const String kApiEndpoint = "http://192.168.1.27:8000/detect-card-box";

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
    // This keeps the camera preview running at high FPS
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
      // Taking a picture without stopping the stream first is often faster on Android
      final XFile file = await _cameraController!.takePicture();

      // Stop the stream AFTER taking the picture to keep the preview alive as long as possible
      // or just keep it stopped during the confirmation phase.
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
  bool _isUploading = false;
  String? _croppedPath;

  Future<void> _onCropPressed() async {
    if (widget.detectedRect == null || widget.streamSize == null) return;

    setState(() {
      _isUploading = true;
    });

    try {
      final bytes = await File(widget.imagePath).readAsBytes();
      final original = img.decodeImage(bytes);
      if (original == null) return;

      final rect = widget.detectedRect!;
      final streamSize = widget.streamSize!;

      // Calculate Scaling factors (Photo vs Stream)
      final scaleX = original.width / streamSize.width;
      final scaleY = original.height / streamSize.height;

      final cropX = (rect.left * scaleX).toInt().clamp(0, original.width);
      final cropY = (rect.top * scaleY).toInt().clamp(0, original.height);
      final cropW = (rect.width * scaleX).toInt().clamp(1, original.width - cropX);
      final cropH = (rect.height * scaleY).toInt().clamp(1, original.height - cropY);

      final cropped = img.copyCrop(original, x: cropX, y: cropY, width: cropW, height: cropH);
      
      final directory = await getTemporaryDirectory();
      final path = '${directory.path}/crop_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final croppedFile = File(path);
      await croppedFile.writeAsBytes(img.encodeJpg(cropped));

      setState(() {
        _croppedPath = path;
      });
    } catch (e) {
      debugPrint("Crop error: $e");
    } finally {
      setState(() {
        _isUploading = false;
      });
    }
  }

  Future<void> _onCheckPressed() async {
    setState(() {
      _isUploading = true;
    });

    try {
      final imageToUpload = File(_croppedPath ?? widget.imagePath);
      final response = await _uploadImage(imageToUpload);

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ResultScreen(
            imagePath: widget.imagePath,
            apiResponse: response,
          ),
        ),
      );
    } catch (e) {
      debugPrint("API Error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: $e")),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isUploading = false;
        });
      }
    }
  }

  Future<Map<String, dynamic>> _uploadImage(File imageFile) async {
    var request = http.MultipartRequest('POST', Uri.parse(kApiEndpoint));
    request.files.add(await http.MultipartFile.fromPath(
      'file',
      imageFile.path,
      contentType: MediaType('image', 'jpeg'),
    ));

    var streamedResponse = await request.send();
    var response = await http.Response.fromStream(streamedResponse);

    debugPrint("API Status Code: ${response.statusCode}");
    debugPrint("API Response Body: ${response.body}");

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      return {
        "success": false,
        "message": "Server error: ${response.statusCode}",
      };
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text("Confirm Image"),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Center(
                  child: Image.file(File(_croppedPath ?? widget.imagePath), key: ValueKey(_croppedPath)),
                ),
                if (_croppedPath == null && widget.detectedRect != null && widget.streamSize != null)
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        return FutureBuilder<Size>(
                          future: _getImageSize(File(widget.imagePath)),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) return Container();
                            final imageSize = snapshot.data!;

                            final rect = widget.detectedRect!;

                            // Image displayed size
                            final displayedWidth = constraints.maxWidth;
                            final displayedHeight = displayedWidth * (imageSize.height / imageSize.width);

                            // Center offset
                            final offsetY = (constraints.maxHeight - displayedHeight) / 2;

                            // Scale factors
                            final scaleX = displayedWidth / widget.streamSize!.width;
                            final scaleY = displayedHeight / widget.streamSize!.height;

                            // Rectangle corners
                            final left = rect.left * scaleX;
                            final top = rect.top * scaleY + offsetY;
                            final right = rect.right * scaleX;
                            final bottom = rect.bottom * scaleY + offsetY;

                            final points = [
                              Offset(left, top), // TL
                              Offset(right, top), // TR
                              Offset(right, bottom), // BR
                              Offset(left, bottom), // BL
                            ];

                            return GestureDetector(
                              onTap: _onCropPressed,
                              child: CustomPaint(
                                painter: SimplePolygonPainter(points: points),
                              ),
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
            child: _isUploading
                ? const Center(child: CircularProgressIndicator())
                : Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 50),
                            side: const BorderSide(color: Colors.white, width: 2),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: const Text("Retake", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        ),
                      ),
                      if (_croppedPath == null && widget.detectedRect != null) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: _onCropPressed,
                            style: ElevatedButton.styleFrom(
                              minimumSize: const Size(0, 50),
                              backgroundColor: Colors.blueAccent,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            child: const Text("Crop", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                      const SizedBox(width: 16),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _onCheckPressed,
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size(0, 50),
                            backgroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: const Text("Check", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Future<Size> _getImageSize(File file) async {
    final bytes = await file.readAsBytes();
    final image = img.decodeImage(bytes);
    if (image == null) return const Size(0, 0);
    return Size(image.width.toDouble(), image.height.toDouble());
  }
}

class SimplePolygonPainter extends CustomPainter {
  final List<Offset> points;

  SimplePolygonPainter({required this.points});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.greenAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;

    if (points.length < 4) return;

    final path = Path()
      ..moveTo(points[0].dx, points[0].dy)
      ..lineTo(points[1].dx, points[1].dy)
      ..lineTo(points[2].dx, points[2].dy)
      ..lineTo(points[3].dx, points[3].dy)
      ..close();

    canvas.drawPath(path, paint);

    final dotPaint = Paint()..color = Colors.greenAccent;
    for (var point in points) {
      canvas.drawCircle(point, 6, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant SimplePolygonPainter oldDelegate) => true;
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
      ..color = Colors.greenAccent.withOpacity(0.1);

    for (final object in objects) {
      final rect = _translateRect(
        object.boundingBox,
        imageSize,
        size,
        rotation,
        lensDirection,
      );

      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(8)), paintFill);

      const double cornerSize = 25.0;
      final path = Path()
        ..moveTo(rect.left, rect.top + cornerSize)
        ..lineTo(rect.left, rect.top)
        ..lineTo(rect.left + cornerSize, rect.top)
        ..moveTo(rect.right - cornerSize, rect.top)
        ..lineTo(rect.right, rect.top)
        ..lineTo(rect.right, rect.top + cornerSize)
        ..moveTo(rect.right, rect.bottom - cornerSize)
        ..lineTo(rect.right, rect.bottom)
        ..lineTo(rect.right - cornerSize, rect.bottom)
        ..moveTo(rect.left + cornerSize, rect.bottom)
        ..lineTo(rect.left, rect.bottom)
        ..lineTo(rect.left, rect.bottom - cornerSize);

      canvas.drawPath(path, paintCorners);

      // Define the 4 corner points based on the translated rect for live feedback
      final topLeft = Offset(rect.left, rect.top);
      final topRight = Offset(rect.right, rect.top);
      final bottomLeft = Offset(rect.left, rect.bottom);
      final bottomRight = Offset(rect.right, rect.bottom);

      final dotPaint = Paint()..color = Colors.greenAccent;
      canvas.drawCircle(topLeft, 6, dotPaint);
      canvas.drawCircle(topRight, 6, dotPaint);
      canvas.drawCircle(bottomLeft, 6, dotPaint);
      canvas.drawCircle(bottomRight, 6, dotPaint);
    }
  }

  Rect _translateRect(Rect rect, Size imageSize, Size widgetSize, InputImageRotation rotation, CameraLensDirection lensDirection) {
    // Standard scaling without axis swap, assuming orientations are now aligned
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
  bool shouldRepaint(ObjectDetectorPainter oldDelegate) {
    return oldDelegate.objects != objects || oldDelegate.imageSize != imageSize;
  }
}

class ResultScreen extends StatelessWidget {
  final String imagePath;
  final Map<String, dynamic> apiResponse;

  const ResultScreen({
    super.key,
    required this.imagePath,
    required this.apiResponse,
  });

  @override
  Widget build(BuildContext context) {
    final bool success = apiResponse['success'] ?? false;
    final String message = apiResponse['message'] ?? "Unknown error";

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(success ? 'Card Detected' : 'Detection Failed'),
        backgroundColor: Colors.transparent,
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: success
                  ? CardResultPreview(
                      imagePath: imagePath,
                      apiData: apiResponse['data'],
                    )
                  : Padding(
                      padding: const EdgeInsets.all(20.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.error_outline, size: 80, color: Colors.red),
                          const SizedBox(height: 16),
                          Text(
                            message,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(24.0),
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(double.infinity, 50),
                backgroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Back to Camera', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }
}

class CardResultPreview extends StatelessWidget {
  final String imagePath;
  final Map<String, dynamic>? apiData;

  const CardResultPreview({
    super.key,
    required this.imagePath,
    this.apiData,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return FutureBuilder<Size>(
          future: _getImageSize(File(imagePath)),
          builder: (context, snapshot) {
            if (!snapshot.hasData) return const CircularProgressIndicator();
            final imageSize = snapshot.data!;

            // Calculate scale factors
            final scaleX = constraints.maxWidth / imageSize.width;
            final widgetHeight = constraints.maxWidth * (imageSize.height / imageSize.width);
            final scaleY = widgetHeight / imageSize.height;

            List<Offset> corners = [];
            if (apiData != null) {
              // Try to get 4 corners first
              if (apiData!.containsKey('topleft')) {
                corners = [
                  Offset(apiData!['topleft']['x'].toDouble() * scaleX, apiData!['topleft']['y'].toDouble() * scaleY),
                  Offset(apiData!['topright']['x'].toDouble() * scaleX, apiData!['topright']['y'].toDouble() * scaleY),
                  Offset(apiData!['bottomright']['x'].toDouble() * scaleX, apiData!['bottomright']['y'].toDouble() * scaleY),
                  Offset(apiData!['bottomleft']['x'].toDouble() * scaleX, apiData!['bottomleft']['y'].toDouble() * scaleY),
                ];
              } else if (apiData!.containsKey('box')) {
                // Fallback to box
                final box = apiData!['box'];
                final left = box['x'].toDouble() * scaleX;
                final top = box['y'].toDouble() * scaleY;
                final width = box['width'].toDouble() * scaleX;
                final height = box['height'].toDouble() * scaleY;
                corners = [
                  Offset(left, top),
                  Offset(left + width, top),
                  Offset(left + width, top + height),
                  Offset(left, top + height),
                ];
              }
            }

            return Stack(
              children: [
                Image.file(File(imagePath)),
                if (corners.isNotEmpty)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: PolygonPainter(points: corners),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  Future<Size> _getImageSize(File file) async {
    final bytes = await file.readAsBytes();
    final image = img.decodeImage(bytes);
    if (image == null) return const Size(0, 0);
    return Size(image.width.toDouble(), image.height.toDouble());
  }
}

class PolygonPainter extends CustomPainter {
  final List<Offset> points;

  PolygonPainter({required this.points});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;

    if (points.length < 4) return;

    final path = Path()
      ..moveTo(points[0].dx, points[0].dy)
      ..lineTo(points[1].dx, points[1].dy)
      ..lineTo(points[2].dx, points[2].dy)
      ..lineTo(points[3].dx, points[3].dy)
      ..close();

    canvas.drawPath(path, paint);

    // Draw small circles at corners for professional look
    final dotPaint = Paint()..color = Colors.red;
    for (var point in points) {
      canvas.drawCircle(point, 5, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant PolygonPainter oldDelegate) => true;
}
