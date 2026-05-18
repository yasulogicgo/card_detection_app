import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'opencv_service.dart';

const String kApiEndpoint = "http://192.168.1.27:8000/detect-card-box";

Map<String, dynamic> _refineDetectionOnImageIsolate(Uint8List imageBytes) {
  final detection = OpenCvService().refineDetectionOnImage(imageBytes);
  return {
    'left': detection.left,
    'top': detection.top,
    'right': detection.right,
    'bottom': detection.bottom,
    'score': detection.score,
    'corners': detection.corners
        ?.map((corner) => {'x': corner.dx, 'y': corner.dy})
        .toList(),
  };
}

Uint8List? _warpCardIsolate(Map<String, dynamic> params) {
  final bytes = params['bytes'] as Uint8List;
  final cornersData = params['corners'] as List<dynamic>;
  final corners = cornersData
      .map(
        (corner) => Offset(
          (corner['x'] as num).toDouble(),
          (corner['y'] as num).toDouble(),
        ),
      )
      .toList();
  return OpenCvService().getWarpedCard(bytes, corners);
}

class CardScannerScreen extends StatefulWidget {
  const CardScannerScreen({super.key});

  @override
  State<CardScannerScreen> createState() => _CardScannerScreenState();
}

class _CardScannerScreenState extends State<CardScannerScreen> {
  CameraController? _cameraController;
  bool _isProcessing = false;
  bool _isCapturing = false;
  bool _isInitializingCamera = true;
  String? _cameraError;

  List<Offset>? _openCvCorners;
  Rect? _transformedRect;
  Size? _imageSize;
  double _detectionScore = 0.0;

  // Sensor variables
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;
  double _tiltX = 0;
  double _tiltY = 0;
  bool _isDeviceLevel = false;

  int? _lastProcessTime;
  int? _lastUiUpdateTime;

  @override
  void initState() {
    super.initState();
    debugPrint("DETECTOR CREATED");
    _initialize();
    _startSensorTracking();
  }

  void _startSensorTracking() {
    _accelerometerSubscription = accelerometerEventStream().listen((
      AccelerometerEvent event,
    ) {
      if (!mounted) return;
      double x = event.x;
      double y = event.y;
      double z = event.z;
      double tilt =
          math.acos(z / math.sqrt(x * x + y * y + z * z)) * (180 / math.pi);
      setState(() {
        _tiltX = x;
        _tiltY = y;
        _isDeviceLevel = tilt < 15.0;
      });
    });
  }

  Future<void> _initialize() async {
    if (mounted) {
      setState(() {
        _isInitializingCamera = true;
        _cameraError = null;
      });
    }

    try {
      final cameras = await availableCameras();
      final backCameras = cameras
          .where((camera) => camera.lensDirection == CameraLensDirection.back)
          .toList();
      if (backCameras.isEmpty) {
        throw CameraException(
          'no_back_camera',
          'No back camera was found on this device.',
        );
      }
      final backCamera = backCameras.first;

      _cameraController = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );

      await _cameraController!.initialize();
      await _cameraController!.lockCaptureOrientation(
        DeviceOrientation.portraitUp,
      );

      debugPrint("STREAM START");
      await _cameraController!.startImageStream(_processCameraImage);
      if (mounted) {
        setState(() {
          _isInitializingCamera = false;
          _cameraError = null;
        });
      }
    } catch (e, stack) {
      debugPrint('Camera initialization error: $e');
      debugPrint('$stack');
      await _cameraController?.dispose();
      _cameraController = null;

      if (mounted) {
        setState(() {
          _isInitializingCamera = false;
          _cameraError = _mapCameraError(e);
        });
      }
    }
  }

  String _mapCameraError(Object error) {
    if (error is CameraException) {
      switch (error.code) {
        case 'CameraAccessDenied':
          return 'Camera permission was denied. Please allow camera access and try again.';
        case 'CameraAccessDeniedWithoutPrompt':
          return 'Camera permission was denied permanently. Enable it from system settings.';
        case 'CameraAccessRestricted':
          return 'Camera access is restricted on this device.';
        case 'no_back_camera':
          return error.description ?? 'Back camera is not available on this device.';
      }

      if (error.description != null && error.description!.trim().isNotEmpty) {
        return error.description!;
      }
    }

    return 'Unable to start the camera. Please try again.';
  }

  Future<void> _processCameraImage(CameraImage image) async {
    debugPrint("FRAME RECEIVED");

    if (_isProcessing) {
      debugPrint("SKIP FRAME");
      return;
    }

    if (_isCapturing) {
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastProcessTime != null && now - _lastProcessTime! < 1200)
      return; // Further throttle to keep the buffer from backing up
    _lastProcessTime = now;

    _isProcessing = true;
    debugPrint("PROCESS START");

    try {
      debugPrint("FORMAT: ${image.format.group}");
      debugPrint("SIZE: ${image.width} x ${image.height}");

      final bytes = await _convertCameraImageToJpeg(image);
      final detectionData = await compute(
        _refineDetectionOnImageIsolate,
        bytes,
      );
      final score = (detectionData['score'] as double?) ?? 0.0;
      debugPrint(
        'DETECTION: score=$score corners=${(detectionData['corners'] as List?)?.length ?? 0}',
      );

      List<Offset>? corners;
      if (score > 0 && detectionData['corners'] is List) {
        corners = (detectionData['corners'] as List<dynamic>)
            .map(
              (corner) => Offset(
                (corner['x'] as num).toDouble(),
                (corner['y'] as num).toDouble(),
              ),
            )
            .toList();
      }

      if (mounted && _shouldUpdateUi(corners)) {
        setState(() {
          _openCvCorners = corners;
          _detectionScore = score;
          if (corners != null && corners.length == 4) {
            final xs = corners.map((e) => e.dx).toList();
            final ys = corners.map((e) => e.dy).toList();
            _transformedRect = Rect.fromLTRB(
              xs.reduce(math.min),
              ys.reduce(math.min),
              xs.reduce(math.max),
              ys.reduce(math.max),
            );
          } else {
            _transformedRect = null;
          }

          final rotation =
              _cameraController?.description.sensorOrientation ?? 0;
          _imageSize = (rotation == 90 || rotation == 270)
              ? Size(image.height.toDouble(), image.width.toDouble())
              : Size(image.width.toDouble(), image.height.toDouble());
        });
      }
    } catch (e) {
      debugPrint("ERROR: $e");
    } finally {
      debugPrint("PROCESS END");
      _isProcessing = false;
    }
  }

  bool _shouldUpdateUi(List<Offset>? corners) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastUiUpdateTime != null && now - _lastUiUpdateTime! < 200) {
      return false;
    }

    final bool changed = !_offsetListEquals(_openCvCorners, corners);
    if (changed) {
      _lastUiUpdateTime = now;
      return true;
    }

    return false;
  }

  bool _offsetListEquals(List<Offset>? a, List<Offset>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<Uint8List> _convertCameraImageToJpeg(CameraImage image) async {
    final converted = _convertCameraImage(image);
    if (converted == null) {
      throw StateError(
        'Unsupported camera image format: ${image.format.group}',
      );
    }
    return Uint8List.fromList(img.encodeJpg(converted, quality: 80));
  }

  img.Image? _convertCameraImage(CameraImage image) {
    try {
      if (image.format.group == ImageFormatGroup.yuv420) {
        return _convertYUV420(image);
      }
      if (image.format.group == ImageFormatGroup.nv21) {
        return _convertNV21(image);
      }
      if (image.format.group == ImageFormatGroup.bgra8888) {
        return _convertBGRA8888(image);
      }
      return null;
    } catch (e) {
      debugPrint('CONVERT ERROR: $e');
      return null;
    }
  }

  img.Image _convertBGRA8888(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final bytes = image.planes[0].bytes;
    return img.Image.fromBytes(
      width: width,
      height: height,
      bytes: bytes.buffer,
      order: img.ChannelOrder.bgra,
      numChannels: 4,
    );
  }

  img.Image _convertYUV420(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final rgb = img.Image(width: width, height: height);

    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    final yBytes = yPlane.bytes;
    final uBytes = uPlane.bytes;
    final vBytes = vPlane.bytes;

    final yRowStride = yPlane.bytesPerRow;
    final uvRowStride = uPlane.bytesPerRow;
    final uvPixelStride = uPlane.bytesPerPixel ?? 1;

    for (int row = 0; row < height; row++) {
      final yRow = row * yRowStride;
      final uvRow = (row >> 1) * uvRowStride;

      for (int col = 0; col < width; col++) {
        final yIndex = yRow + col;
        final uvIndex = uvRow + ((col >> 1) * uvPixelStride);

        if (yIndex >= yBytes.length ||
            uvIndex >= uBytes.length ||
            uvIndex >= vBytes.length) {
          continue;
        }

        final yp = yBytes[yIndex];
        final up = uBytes[uvIndex];
        final vp = vBytes[uvIndex];

        int r = (yp + 1.402 * (vp - 128)).round();
        int g = (yp - 0.344136 * (up - 128) - 0.714136 * (vp - 128)).round();
        int b = (yp + 1.772 * (up - 128)).round();

        r = r.clamp(0, 255);
        g = g.clamp(0, 255);
        b = b.clamp(0, 255);

        rgb.setPixelRgb(col, row, r, g, b);
      }
    }

    return rgb;
  }

  img.Image _convertNV21(CameraImage image) {
    if (image.planes.isEmpty) {
      throw StateError('NV21 image has no planes');
    }

    final width = image.width;
    final height = image.height;
    final rgb = img.Image(width: width, height: height);
    final bytes = image.planes[0].bytes;
    final yRowStride = image.planes[0].bytesPerRow;
    final int frameSize = width * height;

    for (int row = 0; row < height; row++) {
      final yRow = row * yRowStride;
      for (int col = 0; col < width; col++) {
        final yIndex = yRow + col;
        final uvIndex = frameSize + (row >> 1) * width + (col & ~1);

        if (yIndex >= bytes.length || uvIndex + 1 >= bytes.length) {
          continue;
        }

        final yp = bytes[yIndex];
        final vp = bytes[uvIndex];
        final up = bytes[uvIndex + 1];

        int r = (yp + 1.402 * (vp - 128)).round();
        int g = (yp - 0.344136 * (up - 128) - 0.714136 * (vp - 128)).round();
        int b = (yp + 1.772 * (up - 128)).round();

        r = r.clamp(0, 255);
        g = g.clamp(0, 255);
        b = b.clamp(0, 255);

        rgb.setPixelRgb(col, row, r, g, b);
      }
    }

    return rgb;
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
        !_cameraController!.value.isInitialized)
      return;

    final currentRect = _transformedRect;
    final currentStreamSize = _imageSize;

    setState(() {
      _isCapturing = true;
      _openCvCorners = null;
    });

    try {
      if (_cameraController!.value.isStreamingImages) {
        await _cameraController!.stopImageStream();
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

      if (mounted) _resumeStream();
    } catch (e) {
      debugPrint("Capture error: $e");
      _resumeStream();
    }
  }

  void _resumeStream() {
    if (!mounted) return;

    setState(() {
      _isCapturing = false;
      _openCvCorners = null;
      _transformedRect = null;
      _detectionScore = 0.0;
    });

    if (_cameraController == null) return;
    final controllerValue = _cameraController!.value;
    if (controllerValue.isStreamingImages) return;

    _cameraController!.startImageStream(_processCameraImage);
  }

  @override
  void dispose() {
    _accelerometerSubscription?.cancel();
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitializingCamera) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_cameraError != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.camera_alt_outlined, color: Colors.white, size: 64),
                const SizedBox(height: 16),
                Text(
                  _cameraError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _initialize,
                  child: const Text('Retry Camera'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final previewAspectRatio = _cameraController!.value.aspectRatio;

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
          if (_openCvCorners != null || _transformedRect != null)
            IgnorePointer(
              child: Center(
                child: AspectRatio(
                  aspectRatio: previewAspectRatio,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_openCvCorners != null)
                        CustomPaint(
                          painter: SimplePolygonPainter(
                            points: _openCvCorners!,
                          ),
                        ),
                      if (_transformedRect != null)
                        CustomPaint(
                          painter: SimpleBoxPainter(
                            _transformedRect!,
                            const Size(1, 1),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          if (!_isCapturing && _detectionScore > 0)
            Positioned(
              top: 120,
              left: 16,
              right: 16,
              child: Align(
                alignment: Alignment.topCenter,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.greenAccent, width: 1.5),
                  ),
                  child: Text(
                    'Detection score: ${(_detectionScore * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),

          if (!_isCapturing)
            Positioned(
              top: 60,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: _isDeviceLevel
                        ? Colors.green.withValues(alpha: 0.8)
                        : Colors.red.withValues(alpha: 0.8),
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
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

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
                        decoration: const BoxDecoration(
                          color: Colors.white24,
                          shape: BoxShape.circle,
                        ),
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
                      backgroundColor: _isDeviceLevel
                          ? Colors.white
                          : Colors.grey,
                      child: Icon(
                        Icons.camera_alt,
                        color: _isDeviceLevel ? Colors.black : Colors.white54,
                        size: 28,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class SimpleBoxPainter extends CustomPainter {
  final Rect rect;
  final Size imageSize;
  SimpleBoxPainter(this.rect, this.imageSize);

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;
    final paint = Paint()
      ..color = Colors.greenAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;
    final scaledRect = Rect.fromLTRB(
      rect.left * scaleX,
      rect.top * scaleY,
      rect.right * scaleX,
      rect.bottom * scaleY,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(scaledRect, const Radius.circular(8)),
      paint,
    );
    final dotPaint = Paint()..color = Colors.greenAccent;
    canvas.drawCircle(scaledRect.topLeft, 6, dotPaint);
    canvas.drawCircle(scaledRect.topRight, 6, dotPaint);
    canvas.drawCircle(scaledRect.bottomLeft, 6, dotPaint);
    canvas.drawCircle(scaledRect.bottomRight, 6, dotPaint);
  }

  @override
  bool shouldRepaint(covariant SimpleBoxPainter oldDelegate) => true;
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
  List<Offset>? _openCvCorners;
  final OpenCvService _openCvService = OpenCvService();

  @override
  void initState() {
    super.initState();
    _findProperCorners();
  }

  Future<void> _findProperCorners() async {
    try {
      final bytes = await File(widget.imagePath).readAsBytes();
      final detectionData = await compute(
        _refineDetectionOnImageIsolate,
        bytes,
      );
      if (mounted && (detectionData['score'] as double) > 0) {
        setState(() {
          _openCvCorners = (detectionData['corners'] as List<dynamic>)
              .map(
                (corner) => Offset(
                  (corner['x'] as num).toDouble(),
                  (corner['y'] as num).toDouble(),
                ),
              )
              .toList();
        });
      }
    } catch (e) {
      debugPrint("OpenCV Isolate Error: $e");
    }
  }

  Future<void> _onCheckPressed() async {
    setState(() => _isUploading = true);
    try {
      final imageFile = File(_croppedPath ?? widget.imagePath);
      final response = await _uploadImage(imageFile);
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) =>
              ResultScreen(imagePath: imageFile.path, apiResponse: response),
        ),
      );
    } catch (e) {
      debugPrint("API Error: $e");
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<void> _onCropPressed() async {
    if (_openCvCorners == null) return;
    setState(() => _isUploading = true);
    try {
      final bytes = await File(widget.imagePath).readAsBytes();
      final warped = await compute(_warpCardIsolate, {
        'bytes': bytes,
        'corners': _openCvCorners!
            .map((corner) => {'x': corner.dx, 'y': corner.dy})
            .toList(),
      });
      if (warped != null) {
        final directory = await getTemporaryDirectory();
        final path =
            '${directory.path}/crop_${DateTime.now().millisecondsSinceEpoch}.jpg';
        await File(path).writeAsBytes(warped);
        setState(() => _croppedPath = path);
      }
    } catch (e) {
      debugPrint("Crop error: $e");
    } finally {
      setState(() => _isUploading = false);
    }
  }

  Future<Map<String, dynamic>> _uploadImage(File imageFile) async {
    var request = http.MultipartRequest('POST', Uri.parse(kApiEndpoint));
    request.files.add(
      await http.MultipartFile.fromPath(
        'file',
        imageFile.path,
        contentType: MediaType('image', 'jpeg'),
      ),
    );
    var response = await http.Response.fromStream(await request.send());
    debugPrint("API Status: ${response.statusCode}\nBody: ${response.body}");
    if (response.statusCode == 200) return json.decode(response.body);
    return {
      "success": false,
      "message": "Server error: ${response.statusCode}",
    };
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
                  child: Image.file(
                    File(_croppedPath ?? widget.imagePath),
                    key: ValueKey(_croppedPath),
                  ),
                ),
                if (_croppedPath == null && _openCvCorners != null)
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        return FutureBuilder<Size>(
                          future: _getImageSize(File(widget.imagePath)),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) return Container();
                            return GestureDetector(
                              onTap: _onCropPressed,
                              child: CustomPaint(
                                painter: SimplePolygonPainter(
                                  points: _openCvCorners!,
                                ),
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
                            side: const BorderSide(
                              color: Colors.white,
                              width: 2,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text(
                            "Retake",
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      if (_croppedPath == null && _openCvCorners != null) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: _onCropPressed,
                            style: ElevatedButton.styleFrom(
                              minimumSize: const Size(0, 50),
                              backgroundColor: Colors.blueAccent,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text(
                              "Crop",
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
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
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text(
                            "Check",
                            style: TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
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
    return image == null
        ? const Size(0, 0)
        : Size(image.width.toDouble(), image.height.toDouble());
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
    final scaled = points
        .map((point) => Offset(point.dx * size.width, point.dy * size.height))
        .toList();
    final path = Path()
      ..moveTo(scaled[0].dx, scaled[0].dy)
      ..lineTo(scaled[1].dx, scaled[1].dy)
      ..lineTo(scaled[2].dx, scaled[2].dy)
      ..lineTo(scaled[3].dx, scaled[3].dy)
      ..close();
    canvas.drawPath(path, paint);
    final dotPaint = Paint()..color = Colors.greenAccent;
    for (var p in scaled) {
      canvas.drawCircle(p, 6, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant SimplePolygonPainter oldDelegate) => true;
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
                          const Icon(
                            Icons.error_outline,
                            size: 80,
                            color: Colors.red,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            apiResponse['message'] ?? "Unknown error",
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
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
            final widgetHeight =
                constraints.maxWidth * (imageSize.height / imageSize.width);
            final scaleY = widgetHeight / imageSize.height;
            List<Offset> corners = [];
            if (apiData != null) {
              if (apiData!.containsKey('topleft')) {
                corners = [
                  Offset(
                    apiData!['topleft']['x'].toDouble() * scaleX,
                    apiData!['topleft']['y'].toDouble() * scaleY,
                  ),
                  Offset(
                    apiData!['topright']['x'].toDouble() * scaleX,
                    apiData!['topright']['y'].toDouble() * scaleY,
                  ),
                  Offset(
                    apiData!['bottomright']['x'].toDouble() * scaleX,
                    apiData!['bottomright']['y'].toDouble() * scaleY,
                  ),
                  Offset(
                    apiData!['bottomleft']['x'].toDouble() * scaleX,
                    apiData!['bottomleft']['y'].toDouble() * scaleY,
                  ),
                ];
              } else if (apiData!.containsKey('box')) {
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
    return image == null
        ? const Size(0, 0)
        : Size(image.width.toDouble(), image.height.toDouble());
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
    final dotPaint = Paint()..color = Colors.red;
    for (var p in points) {
      canvas.drawCircle(p, 5, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant PolygonPainter oldDelegate) => true;
}
