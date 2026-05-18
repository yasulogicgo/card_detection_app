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
  Size? _previewCoordinateSize;
  bool _isFirstCropApplied = false;

  static const double _innerPadding = 20.0;
  static const double _defaultPadding = 60.0; // Increased padding for easier settlement
  static const double _minGap = 12.0;

  @override
  void initState() {
    super.initState();
    _initializePreviewState();
  }

  void _initializePreviewState() {
    final streamSize = widget.streamSize;
    final detectedRect = widget.detectedRect;
    if (streamSize == null || detectedRect == null) return;

    final normalizedDetected = Rect.fromLTRB(
      detectedRect.left.clamp(0.0, streamSize.width).toDouble(),
      detectedRect.top.clamp(0.0, streamSize.height).toDouble(),
      detectedRect.right.clamp(0.0, streamSize.width).toDouble(),
      detectedRect.bottom.clamp(0.0, streamSize.height).toDouble(),
    );

    _detectedRectOriginal = normalizedDetected;
    _previewCoordinateSize = streamSize;
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

      final cropX = (cropRect.left * scaleX).round().clamp(0, original.width - 1);
      final cropY = (cropRect.top * scaleY).round().clamp(0, original.height - 1);
      final cropRight = (cropRect.right * scaleX).round().clamp(cropX + 1, original.width);
      final cropBottom = (cropRect.bottom * scaleY).round().clamp(cropY + 1, original.height);
      final cropW = math.max(1, cropRight - cropX);
      final cropH = math.max(1, cropBottom - cropY);

      final cropped = img.copyCrop(original, x: cropX, y: cropY, width: cropW, height: cropH);

      final directory = await getTemporaryDirectory();
      final path = '${directory.path}/crop_${DateTime.now().millisecondsSinceEpoch}.jpg';
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
        sourcePixelCropRect: Rect.fromLTWH(cropX.toDouble(), cropY.toDouble(), cropW.toDouble(), cropH.toDouble()),
      );
    } catch (e) {
      debugPrint("Crop error: $e");
      return null;
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<void> _onCheckPressed() async {
    setState(() => _isUploading = true);

    try {
      File imageToUpload;
      
      if (_isFirstCropApplied && _guideOuterRect != null && _previewCoordinateSize != null) {
        // PERFORM FINAL PRECISION CROP based on Outer Guide
        final finalCrop = await _cropRectFromImage(
          sourcePath: _croppedPath ?? widget.imagePath,
          cropRect: _guideOuterRect!,
          coordinateSpace: _previewCoordinateSize!,
          updatePreview: false,
        );
        if (finalCrop == null) return;
        imageToUpload = finalCrop.file;
      } else {
        // Fallback to current available image
        imageToUpload = File(_croppedPath ?? widget.imagePath);
      }

      final response = await _uploadImage(imageToUpload);
      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => ResultScreen(imagePath: imageToUpload.path, apiResponse: response)),
      );
    } catch (e) {
      debugPrint("API Error: $e");
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<Map<String, dynamic>> _uploadImage(File imageFile) async {
    var request = http.MultipartRequest('POST', Uri.parse(kApiEndpoint));
    request.files.add(await http.MultipartFile.fromPath('file', imageFile.path, contentType: MediaType('image', 'jpeg')));
    var response = await http.Response.fromStream(await request.send());
    if (response.statusCode == 200) return json.decode(response.body);
    return {"success": false, "message": "Server error: ${response.statusCode}"};
  }

  Future<void> _handleFirstCrop() async {
    final detectedRect = _detectedRectOriginal;
    final previewCoordinateSize = _previewCoordinateSize;
    if (_isFirstCropApplied || detectedRect == null || previewCoordinateSize == null) return;

    final firstCropRect = Rect.fromLTRB(
      math.max(0, detectedRect.left - _defaultPadding),
      math.max(0, detectedRect.top - _defaultPadding),
      math.min(previewCoordinateSize.width, detectedRect.right + _defaultPadding),
      math.min(previewCoordinateSize.height, detectedRect.bottom + _defaultPadding),
    );

    final cropped = await _cropRectFromImage(
      sourcePath: widget.imagePath,
      cropRect: firstCropRect,
      coordinateSpace: previewCoordinateSize,
      updatePreview: true,
    );
    if (cropped == null || !mounted) return;

    final sourceImage = await _getImageSize(File(widget.imagePath));
    final sourceScaleX = sourceImage.width / previewCoordinateSize.width;
    final sourceScaleY = sourceImage.height / previewCoordinateSize.height;

    final detectedPixelRect = Rect.fromLTRB(
      detectedRect.left * sourceScaleX,
      detectedRect.top * sourceScaleY,
      detectedRect.right * sourceScaleX,
      detectedRect.bottom * sourceScaleY,
    );

    final cropPixelRect = cropped.sourcePixelCropRect;
    final mappedOuterGuide = Rect.fromLTRB(
      detectedPixelRect.left - cropPixelRect.left,
      detectedPixelRect.top - cropPixelRect.top,
      detectedPixelRect.right - cropPixelRect.left,
      detectedPixelRect.bottom - cropPixelRect.top,
    );
    final mappedInnerGuide = Rect.fromLTRB(
      (mappedOuterGuide.left + _innerPadding).clamp(0.0, mappedOuterGuide.right - _minGap),
      (mappedOuterGuide.top + _innerPadding).clamp(0.0, mappedOuterGuide.bottom - _minGap),
      (mappedOuterGuide.right - _innerPadding).clamp(mappedOuterGuide.left + _minGap, cropped.croppedSize.width),
      (mappedOuterGuide.bottom - _innerPadding).clamp(mappedOuterGuide.top + _minGap, cropped.croppedSize.height),
    );

    setState(() {
      _isFirstCropApplied = true;
      _firstCropRect = firstCropRect;
      _previewCoordinateSize = cropped.croppedSize;
      _guideOuterRect = mappedOuterGuide;
      _guideInnerRect = mappedInnerGuide;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text("Preview"), backgroundColor: Colors.transparent, elevation: 0),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Center(
                  child: Image.file(
                    File(_croppedPath ?? widget.imagePath),
                    key: ValueKey(_croppedPath),
                    fit: BoxFit.contain,
                  ),
                ),
                if (!_isFirstCropApplied && _detectedRectOriginal != null && _previewCoordinateSize != null)
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        return FutureBuilder<Size>(
                          future: _getImageSize(File(widget.imagePath)),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) return Container();
                            final displayRect = _getDisplayedImageRect(containerSize: Size(constraints.maxWidth, constraints.maxHeight), imageSize: snapshot.data!);
                            return CropEditorOverlay(imageBounds: displayRect, streamSize: _previewCoordinateSize!, detectedRect: _detectedRectOriginal!, onBackgroundTap: _handleFirstCrop);
                          },
                        );
                      },
                    ),
                  ),
                if (_isFirstCropApplied && _croppedPath != null && _guideOuterRect != null && _guideInnerRect != null && _previewCoordinateSize != null)
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        return FutureBuilder<Size>(
                          future: _getImageSize(File(_croppedPath!)),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) return Container();
                            final displayRect = _getDisplayedImageRect(containerSize: Size(constraints.maxWidth, constraints.maxHeight), imageSize: snapshot.data!);
                            return SecondStageCropOverlay(
                              imageBounds: displayRect,
                              streamSize: _previewCoordinateSize!,
                              outerGuideRect: _guideOuterRect!,
                              innerGuideRect: _guideInnerRect!,
                              onOuterChanged: (rect) => setState(() => _guideOuterRect = rect),
                              onInnerChanged: (rect) => setState(() => _guideInnerRect = rect),
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
            decoration: const BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
            child: _isUploading
                ? const Center(child: CircularProgressIndicator())
                : Row(
                    children: [
                      Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(context), style: OutlinedButton.styleFrom(minimumSize: const Size(0, 50), side: const BorderSide(color: Colors.white, width: 2), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))), child: const Text("Retake", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)))),
                      const SizedBox(width: 8),
                      Expanded(child: ElevatedButton(onPressed: _handleFirstCrop, style: ElevatedButton.styleFrom(minimumSize: const Size(0, 50), backgroundColor: const Color(0xFF4A80F0), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))), child: const Text("Crop", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)))),
                      const SizedBox(width: 8),
                      Expanded(child: ElevatedButton(onPressed: _onCheckPressed, style: ElevatedButton.styleFrom(minimumSize: const Size(0, 50), backgroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))), child: const Text("Check", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)))),
                    ],
                  ),
          ),
          if (_isFirstCropApplied && _croppedPath != null && _guideOuterRect != null && _guideInnerRect != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  Expanded(child: _buildMetricCard("Main +20", _formatSplitValue(_guideInnerRect!.left - _guideOuterRect!.left, _guideOuterRect!.right - _guideInnerRect!.right))),
                  const SizedBox(width: 12),
                  Expanded(child: _buildMetricCard("Outer +40", _formatSplitValue(_guideInnerRect!.top - _guideOuterRect!.top, _guideOuterRect!.bottom - _guideInnerRect!.bottom))),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Rect _getDisplayedImageRect({required Size containerSize, required Size imageSize}) {
    final scale = math.min(containerSize.width / imageSize.width, containerSize.height / imageSize.height);
    final width = imageSize.width * scale;
    final height = imageSize.height * scale;
    return Rect.fromLTWH((containerSize.width - width) / 2, (containerSize.height - height) / 2, width, height);
  }

  Widget _buildMetricCard(String title, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(color: const Color(0xFF161616), borderRadius: BorderRadius.circular(18)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
      ]),
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
    return image == null ? const Size(0, 0) : Size(image.width.toDouble(), image.height.toDouble());
  }
}

class CropEditorOverlay extends StatelessWidget {
  final Rect imageBounds;
  final Size streamSize;
  final Rect detectedRect;
  final VoidCallback onBackgroundTap;
  const CropEditorOverlay({super.key, required this.imageBounds, required this.streamSize, required this.detectedRect, required this.onBackgroundTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(behavior: HitTestBehavior.translucent, onTap: onBackgroundTap, child: CustomPaint(painter: CropOverlayPainter(imageBounds: imageBounds, streamSize: streamSize, detectedRect: detectedRect)));
  }
}

class CropOverlayPainter extends CustomPainter {
  final Rect imageBounds;
  final Size streamSize;
  final Rect detectedRect;
  const CropOverlayPainter({required this.imageBounds, required this.streamSize, required this.detectedRect});
  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = imageBounds.width / streamSize.width;
    final scaleY = imageBounds.height / streamSize.height;
    final displayRect = Rect.fromLTRB(imageBounds.left + (detectedRect.left * scaleX), imageBounds.top + (detectedRect.top * scaleY), imageBounds.left + (detectedRect.right * scaleX), imageBounds.top + (detectedRect.bottom * scaleY));
    canvas.drawRect(displayRect, Paint()..color = Colors.deepPurpleAccent..style = PaintingStyle.stroke..strokeWidth = 3);
  }
  @override
  bool shouldRepaint(covariant CropOverlayPainter oldDelegate) => true;
}

class SecondStageCropOverlay extends StatelessWidget {
  final Rect imageBounds;
  final Size streamSize;
  final Rect outerGuideRect;
  final Rect innerGuideRect;
  final ValueChanged<Rect> onOuterChanged;
  final ValueChanged<Rect> onInnerChanged;

  const SecondStageCropOverlay({super.key, required this.imageBounds, required this.streamSize, required this.outerGuideRect, required this.innerGuideRect, required this.onOuterChanged, required this.onInnerChanged});

  Offset _toDisplayPoint(Offset point) {
    final scaleX = imageBounds.width / streamSize.width;
    final scaleY = imageBounds.height / streamSize.height;
    return Offset(imageBounds.left + (point.dx * scaleX), imageBounds.top + (point.dy * scaleY));
  }

  double _deltaToStreamX(double delta) => delta * streamSize.width / imageBounds.width;
  double _deltaToStreamY(double delta) => delta * streamSize.height / imageBounds.height;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: CustomPaint(painter: ZoomCropOverlayPainter(croppedSize: streamSize, outerGuideRect: outerGuideRect, innerGuideRect: innerGuideRect))),
        _buildHandle(
          point: _toDisplayPoint(Offset((outerGuideRect.left + outerGuideRect.right) / 2, outerGuideRect.top)),
          icon: Icons.keyboard_arrow_up,
          color: Colors.deepPurpleAccent,
          onDrag: (details) {
            final nextTop = (outerGuideRect.top + _deltaToStreamY(details.delta.dy)).clamp(0.0, innerGuideRect.top - _ConfirmationScreenState._minGap);
            onOuterChanged(Rect.fromLTRB(outerGuideRect.left, nextTop, outerGuideRect.right, outerGuideRect.bottom));
          },
        ),
        _buildHandle(
          point: _toDisplayPoint(Offset((outerGuideRect.left + outerGuideRect.right) / 2, outerGuideRect.bottom)),
          icon: Icons.keyboard_arrow_down,
          color: Colors.deepPurpleAccent,
          onDrag: (details) {
            final nextBottom = (outerGuideRect.bottom + _deltaToStreamY(details.delta.dy)).clamp(innerGuideRect.bottom + _ConfirmationScreenState._minGap, streamSize.height);
            onOuterChanged(Rect.fromLTRB(outerGuideRect.left, outerGuideRect.top, outerGuideRect.right, nextBottom));
          },
        ),
        _buildHandle(
          point: _toDisplayPoint(Offset(outerGuideRect.left, (outerGuideRect.top + outerGuideRect.bottom) / 2)),
          icon: Icons.keyboard_arrow_left,
          color: Colors.deepPurpleAccent,
          onDrag: (details) {
            final nextLeft = (outerGuideRect.left + _deltaToStreamX(details.delta.dx)).clamp(0.0, innerGuideRect.left - _ConfirmationScreenState._minGap);
            onOuterChanged(Rect.fromLTRB(nextLeft, outerGuideRect.top, outerGuideRect.right, outerGuideRect.bottom));
          },
        ),
        _buildHandle(
          point: _toDisplayPoint(Offset(outerGuideRect.right, (outerGuideRect.top + outerGuideRect.bottom) / 2)),
          icon: Icons.keyboard_arrow_right,
          color: Colors.deepPurpleAccent,
          onDrag: (details) {
            final nextRight = (outerGuideRect.right + _deltaToStreamX(details.delta.dx)).clamp(innerGuideRect.right + _ConfirmationScreenState._minGap, streamSize.width);
            onOuterChanged(Rect.fromLTRB(outerGuideRect.left, outerGuideRect.top, nextRight, outerGuideRect.bottom));
          },
        ),
        _buildHandle(
          point: _toDisplayPoint(Offset((innerGuideRect.left + innerGuideRect.right) / 2, innerGuideRect.top)),
          icon: Icons.keyboard_arrow_up,
          color: Colors.green,
          onDrag: (details) {
            final nextTop = (innerGuideRect.top + _deltaToStreamY(details.delta.dy)).clamp(outerGuideRect.top + _ConfirmationScreenState._minGap, innerGuideRect.bottom - _ConfirmationScreenState._minGap);
            onInnerChanged(Rect.fromLTRB(innerGuideRect.left, nextTop, innerGuideRect.right, innerGuideRect.bottom));
          },
        ),
        _buildHandle(
          point: _toDisplayPoint(Offset((innerGuideRect.left + innerGuideRect.right) / 2, innerGuideRect.bottom)),
          icon: Icons.keyboard_arrow_down,
          color: Colors.green,
          onDrag: (details) {
            final nextBottom = (innerGuideRect.bottom + _deltaToStreamY(details.delta.dy)).clamp(innerGuideRect.top + _ConfirmationScreenState._minGap, outerGuideRect.bottom - _ConfirmationScreenState._minGap);
            onInnerChanged(Rect.fromLTRB(innerGuideRect.left, innerGuideRect.top, innerGuideRect.right, nextBottom));
          },
        ),
        _buildHandle(
          point: _toDisplayPoint(Offset(innerGuideRect.left, (innerGuideRect.top + innerGuideRect.bottom) / 2)),
          icon: Icons.keyboard_arrow_left,
          color: Colors.green,
          onDrag: (details) {
            final nextLeft = (innerGuideRect.left + _deltaToStreamX(details.delta.dx)).clamp(outerGuideRect.left + _ConfirmationScreenState._minGap, innerGuideRect.right - _ConfirmationScreenState._minGap);
            onInnerChanged(Rect.fromLTRB(nextLeft, innerGuideRect.top, innerGuideRect.right, innerGuideRect.bottom));
          },
        ),
        _buildHandle(
          point: _toDisplayPoint(Offset(innerGuideRect.right, (innerGuideRect.top + innerGuideRect.bottom) / 2)),
          icon: Icons.keyboard_arrow_right,
          color: Colors.green,
          onDrag: (details) {
            final nextRight = (innerGuideRect.right + _deltaToStreamX(details.delta.dx)).clamp(innerGuideRect.left + _ConfirmationScreenState._minGap, outerGuideRect.right - _ConfirmationScreenState._minGap);
            onInnerChanged(Rect.fromLTRB(innerGuideRect.left, innerGuideRect.top, nextRight, innerGuideRect.bottom));
          },
        ),
      ],
    );
  }

  Widget _buildHandle({required Offset point, required IconData icon, required Color color, required GestureDragUpdateCallback onDrag}) {
    return Positioned(left: point.dx - 28, top: point.dy - 28, child: GestureDetector(onPanUpdate: onDrag, child: Container(width: 56, height: 56, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)), child: Icon(icon, color: Colors.white, size: 36))));
  }
}

class ZoomCropOverlayPainter extends CustomPainter {
  final Size croppedSize;
  final Rect outerGuideRect;
  final Rect innerGuideRect;
  const ZoomCropOverlayPainter({required this.croppedSize, required this.outerGuideRect, required this.innerGuideRect});
  Rect _scaleRect(Rect rect, Size size) {
    final scaleX = size.width / croppedSize.width;
    final scaleY = size.height / croppedSize.height;
    return Rect.fromLTRB(rect.left * scaleX, rect.top * scaleY, rect.right * scaleX, rect.bottom * scaleY);
  }
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(_scaleRect(outerGuideRect, size), Paint()..color = Colors.deepPurpleAccent..style = PaintingStyle.stroke..strokeWidth = 2);
    canvas.drawRect(_scaleRect(innerGuideRect, size), Paint()..color = Colors.green..style = PaintingStyle.stroke..strokeWidth = 2);
  }
  @override
  bool shouldRepaint(covariant ZoomCropOverlayPainter oldDelegate) => true;
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
    final Paint paintFill = Paint()..style = PaintingStyle.fill..color = Colors.greenAccent.withOpacity(0.1);
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

class ResultScreen extends StatelessWidget {
  final String imagePath;
  final Map<String, dynamic> apiResponse;
  const ResultScreen({super.key, required this.imagePath, required this.apiResponse});
  @override
  Widget build(BuildContext context) {
    final bool success = apiResponse['success'] ?? false;
    final String message = apiResponse['message'] ?? "Unknown error";
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(success ? 'Card Detected' : 'Detection Failed'), backgroundColor: Colors.transparent),
      body: Column(
        children: [
          Expanded(child: Center(child: success ? CardResultPreview(imagePath: imagePath, apiData: apiResponse['data']) : Padding(padding: const EdgeInsets.all(20.0), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Icons.error_outline, size: 80, color: Colors.red), const SizedBox(height: 16), Text(message, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white))])))),
          Padding(padding: const EdgeInsets.all(24.0), child: ElevatedButton(onPressed: () => Navigator.pop(context), style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 50), backgroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))), child: const Text('Back to Camera', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)))),
        ],
      ),
    );
  }
}

class CardResultPreview extends StatelessWidget {
  final String imagePath;
  final Map<String, dynamic>? apiData;
  const CardResultPreview({super.key, required this.imagePath, this.apiData});
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return FutureBuilder<Size>(
          future: _getImageSize(File(imagePath)),
          builder: (context, snapshot) {
            if (!snapshot.hasData) return const CircularProgressIndicator();
            final imageSize = snapshot.data!;
            final scaleX = constraints.maxWidth / imageSize.width;
            final widgetHeight = constraints.maxWidth * (imageSize.height / imageSize.width);
            final scaleY = widgetHeight / imageSize.height;
            List<Offset> corners = [];
            if (apiData != null) {
              if (apiData!.containsKey('topleft')) {
                corners = [
                  Offset(apiData!['topleft']['x'].toDouble() * scaleX, apiData!['topleft']['y'].toDouble() * scaleY),
                  Offset(apiData!['topright']['x'].toDouble() * scaleX, apiData!['topright']['y'].toDouble() * scaleY),
                  Offset(apiData!['bottomright']['x'].toDouble() * scaleX, apiData!['bottomright']['y'].toDouble() * scaleY),
                  Offset(apiData!['bottomleft']['x'].toDouble() * scaleX, apiData!['bottomleft']['y'].toDouble() * scaleY),
                ];
              } else if (apiData!.containsKey('box')) {
                final box = apiData!['box'];
                final left = box['x'].toDouble() * scaleX;
                final top = box['y'].toDouble() * scaleY;
                final width = box['width'].toDouble() * scaleX;
                final height = box['height'].toDouble() * scaleY;
                corners = [Offset(left, top), Offset(left + width, top), Offset(left + width, top + height), Offset(left, top + height)];
              }
            }
            return Stack(children: [Image.file(File(imagePath)), if (corners.isNotEmpty) Positioned.fill(child: CustomPaint(painter: PolygonPainter(points: corners)))]);
          },
        );
      },
    );
  }
  Future<Size> _getImageSize(File file) async {
    final bytes = await file.readAsBytes();
    final image = img.decodeImage(bytes);
    return image == null ? const Size(0, 0) : Size(image.width.toDouble(), image.height.toDouble());
  }
}

class PolygonPainter extends CustomPainter {
  final List<Offset> points;
  PolygonPainter({required this.points});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.red..style = PaintingStyle.stroke..strokeWidth = 3.0..strokeCap = StrokeCap.round;
    if (points.length < 4) return;
    final path = Path()..moveTo(points[0].dx, points[0].dy)..lineTo(points[1].dx, points[1].dy)..lineTo(points[2].dx, points[2].dy)..lineTo(points[3].dx, points[3].dy)..close();
    canvas.drawPath(path, paint);
    final dotPaint = Paint()..color = Colors.red;
    for (var p in points) canvas.drawCircle(p, 5, dotPaint);
  }
  @override
  bool shouldRepaint(covariant PolygonPainter oldDelegate) => true;
}
