import 'dart:io';
import 'dart:ui';
import 'dart:math'; // sqrt
import 'dart:async'; // Timer
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // DeviceOrientation
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

late List<CameraDescription> cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  cameras = await availableCameras();
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: MyHomePage(title: 'Surya Namaskar Counter'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key, required this.title}) : super(key: key);
  final String title;

  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  CameraController? controller;
  bool isBusy = false;
  late PoseDetector poseDetector;
  late FaceDetector faceDetector;
  CameraImage? img;

  int count = 0;
  String phase = "WAIT_NAMASKAR";
  int selectedCameraIndex = 1; // 0=back, 1=front (using front camera only)

  dynamic _scanResults;
  bool bodyVisible = false;
  bool faceVisible = false;

  // Add a timer to track how long the face has been missing
  Duration _faceMissingDuration = Duration.zero;
  Timer? _faceMissingTimer;
  final Duration _maxFaceMissingTime = Duration(seconds: 3); // Allow face to be missing for up to 3 seconds

  @override
  void initState() {
    super.initState();
    initializeCamera();
  }

  @override
  void dispose() {
    _faceMissingTimer?.cancel();
    controller?.dispose();
    poseDetector.close();
    faceDetector.close();
    super.dispose();
  }

  initializeCamera() async {
    poseDetector = PoseDetector(
      options: PoseDetectorOptions(mode: PoseDetectionMode.stream),
    );

    // Initialize face detector with default options
    faceDetector = FaceDetector(
      options: FaceDetectorOptions(
        enableContours: false,
        enableClassification: false,
        enableLandmarks: false,
        enableTracking: false,
      ),
    );

    // Using front camera only (index 1)
    controller = CameraController(
      cameras[1], // Front camera only
      ResolutionPreset.medium,
      imageFormatGroup:
      Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
    );

    await controller!.initialize();
    if (!mounted) return;

    controller!.startImageStream((image) {
      if (!isBusy) {
        isBusy = true;
        img = image;
        doPoseEstimationOnFrame();
      }
    });

    setState(() {});
  }

  // Camera switching functionality commented out
  /*
  switchCamera() async {
    selectedCameraIndex = (selectedCameraIndex + 1) % cameras.length;
    await controller?.dispose();
    initializeCamera();
  }
  */

  doPoseEstimationOnFrame() async {
    final inputImage = _inputImageFromCameraImage();
    if (inputImage == null) {
      isBusy = false;
      return;
    }

    // First check if there's a face in the frame
    final faces = await faceDetector.processImage(inputImage);
    if (!mounted) return;

    // Handle face detection logic
    if (faces.isEmpty) {
      // If we're in the WAIT_DOWN or WAIT_RETURN phase, allow face to be missing temporarily
      if (phase == "WAIT_DOWN" || phase == "WAIT_RETURN") {
        // Start or continue the timer for face missing
        if (_faceMissingTimer == null) {
          _faceMissingTimer = Timer.periodic(Duration(milliseconds: 100), (timer) {
            _faceMissingDuration += Duration(milliseconds: 100);
            if (_faceMissingDuration > _maxFaceMissingTime) {
              // Face has been missing too long, reset to initial phase
              timer.cancel();
              _faceMissingTimer = null;
              _faceMissingDuration = Duration.zero;
              if (mounted) {
                setState(() {
                  phase = "WAIT_NAMASKAR";
                  faceVisible = false;
                });
              }
            }
          });
        }

        // Continue with pose detection even without face during downward phase
        setState(() {
          faceVisible = false; // Face is not visible but we allow it
        });
      } else {
        // In other phases, require face to be visible
        setState(() {
          faceVisible = false;
          bodyVisible = false;
          _scanResults = [];
        });
        isBusy = false;
        return;
      }
    } else {
      // Face is detected, reset the timer
      _faceMissingTimer?.cancel();
      _faceMissingTimer = null;
      _faceMissingDuration = Duration.zero;
      setState(() {
        faceVisible = true;
      });
    }

    // Only proceed with pose detection if face is detected OR we're in downward phase
    final poses = await poseDetector.processImage(inputImage);
    if (!mounted) return;

    if (poses.isNotEmpty) {
      final pose = poses[0];

      // ✅ Require full body visibility (modified to be more lenient during downward phase)
      if (!isFullBodyVisible(pose)) {
        setState(() {
          bodyVisible = false;
          _scanResults = [];
        });
        isBusy = false;
        return;
      }

      bodyVisible = true;

      final namaskar = detectNamaskar(pose);
      final headDown = detectHeadBelowHips(pose);

      if (phase == "WAIT_NAMASKAR") {
        if (namaskar) {
          setState(() {
            phase = "WAIT_DOWN";
          });
        }
      } else if (phase == "WAIT_DOWN") {
        if (headDown) {
          setState(() {
            phase = "WAIT_RETURN";
          });
        }
      } else if (phase == "WAIT_RETURN") {
        if (namaskar) {
          setState(() {
            count++;
            phase = "WAIT_NAMASKAR";
          });
        }
      }

      setState(() {
        _scanResults = poses;
      });
    } else {
      setState(() {
        _scanResults = [];
      });
    }

    isBusy = false;
  }

  bool isFullBodyVisible(Pose pose) {
    List<PoseLandmarkType> required;

    // During downward phase, be more lenient about visibility
    if (phase == "WAIT_DOWN" || phase == "WAIT_RETURN") {
      required = [
        PoseLandmarkType.leftShoulder,
        PoseLandmarkType.rightShoulder,
        PoseLandmarkType.leftHip,
        PoseLandmarkType.rightHip,
        PoseLandmarkType.leftKnee,
        PoseLandmarkType.rightKnee,
      ];
    } else {
      // In normal phases, require full body visibility
      required = [
        PoseLandmarkType.nose,
        PoseLandmarkType.leftShoulder,
        PoseLandmarkType.rightShoulder,
        PoseLandmarkType.leftHip,
        PoseLandmarkType.rightHip,
        PoseLandmarkType.leftKnee,
        PoseLandmarkType.rightKnee,
        PoseLandmarkType.leftAnkle,
        PoseLandmarkType.rightAnkle,
        PoseLandmarkType.leftWrist,
        PoseLandmarkType.rightWrist,
      ];
    }

    for (final type in required) {
      final lm = pose.landmarks[type];
      if (lm == null || lm.likelihood < 0.4) return false;
    }
    return true;
  }

  bool detectNamaskar(Pose pose) {
    final leftWrist = pose.landmarks[PoseLandmarkType.leftWrist];
    final rightWrist = pose.landmarks[PoseLandmarkType.rightWrist];
    final leftShoulder = pose.landmarks[PoseLandmarkType.leftShoulder];
    final rightShoulder = pose.landmarks[PoseLandmarkType.rightShoulder];

    if (leftWrist == null ||
        rightWrist == null ||
        leftShoulder == null ||
        rightShoulder == null) return false;

    final dx = leftWrist.x - rightWrist.x;
    final dy = leftWrist.y - rightWrist.y;
    final distWrist = sqrt(dx * dx + dy * dy);

    final chestY = (leftShoulder.y + rightShoulder.y) / 2;

    return distWrist < 50 && leftWrist.y < chestY + 100;
  }

  bool detectHeadBelowHips(Pose pose) {
    final nose = pose.landmarks[PoseLandmarkType.nose];
    final leftHip = pose.landmarks[PoseLandmarkType.leftHip];
    final rightHip = pose.landmarks[PoseLandmarkType.rightHip];

    if (nose == null || leftHip == null || rightHip == null) return false;

    final avgHipY = (leftHip.y + rightHip.y) / 2;

    return nose.y > avgHipY + 20; // nose below hips
  }

  final _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  InputImage? _inputImageFromCameraImage() {
    if (img == null) return null;
    final camera = cameras[selectedCameraIndex];
    final sensorOrientation = camera.sensorOrientation;
    InputImageRotation? rotation;

    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    } else if (Platform.isAndroid) {
      var rotationCompensation =
      _orientations[controller!.value.deviceOrientation];
      if (rotationCompensation == null) return null;
      if (camera.lensDirection == CameraLensDirection.front) {
        rotation = InputImageRotationValue.fromRawValue(
            (sensorOrientation + rotationCompensation) % 360);
      } else {
        rotation = InputImageRotationValue.fromRawValue(
            (sensorOrientation - rotationCompensation + 360) % 360);
      }
    }
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(img!.format.raw);
    if (format == null) return null;

    final plane = img!.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(img!.width.toDouble(), img!.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  Widget buildResult() {
    if (_scanResults == null ||
        _scanResults.isEmpty ||
        controller == null ||
        !controller!.value.isInitialized) {
      return Container();
    }

    final Size imageSize = Size(
      controller!.value.previewSize!.height,
      controller!.value.previewSize!.width,
    );

    return CustomPaint(
      painter: PosePainter(imageSize, _scanResults, count, phase),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: controller != null && controller!.value.isInitialized
                ? CameraPreview(controller!)
                : Container(color: Colors.black),
          ),
          Positioned.fill(child: buildResult()),

          // ✅ Show warning when body not visible
          if (!bodyVisible)
            Center(
              child: Container(
                padding: const EdgeInsets.all(24),
                margin: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.red, width: 3),
                ),
                child: const Text(
                  "⚠️ Step back\nFull body not visible",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.redAccent,
                    fontSize: 40,
                    fontWeight: FontWeight.bold,
                    shadows: [
                      Shadow(
                        blurRadius: 8,
                        color: Colors.black,
                        offset: Offset(2, 2),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ✅ Show warning when face not detected (only in phases where face is required)
          if (!faceVisible && (phase == "WAIT_NAMASKAR"))
            Center(
              child: Container(
                padding: const EdgeInsets.all(24),
                margin: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.orange, width: 3),
                ),
                child: const Text(
                  "⚠️ Face not detected\nMake sure you're facing the camera",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    shadows: [
                      Shadow(
                        blurRadius: 8,
                        color: Colors.black,
                        offset: Offset(2, 2),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Count display at the bottom (phase information commented out)
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(16),
              color: Colors.black.withOpacity(0.5),
              child: Text(
                // Commented out phase information, keeping only count
                "Surya Namaskar Count: $count", // Removed phase display
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.yellow,
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                  shadows: [
                    Shadow(
                      blurRadius: 6.0,
                      color: Colors.black,
                      offset: Offset(2, 2),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Camera switch button commented out
          /*
          Positioned(
            bottom: 120,
            left: MediaQuery.of(context).size.width / 2 - 30,
            child: FloatingActionButton(
              onPressed: switchCamera,
              child: const Icon(Icons.cameraswitch),
            ),
          ),
          */
        ],
      ),
    );
  }
}

class PosePainter extends CustomPainter {
  PosePainter(this.absoluteImageSize, this.poses, this.count, this.phase);

  final Size absoluteImageSize;
  final List<Pose> poses;
  final int count;
  final String phase;

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / absoluteImageSize.width;
    final scaleY = size.height / absoluteImageSize.height;

    final pointPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.green;

    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..color = Colors.blueAccent;

    for (final pose in poses) {
      // draw joints
      pose.landmarks.forEach((_, landmark) {
        canvas.drawCircle(
            Offset(landmark.x * scaleX, landmark.y * scaleY), 4, pointPaint);
      });

      // helper to draw lines
      void paintLine(PoseLandmarkType t1, PoseLandmarkType t2) {
        final l1 = pose.landmarks[t1];
        final l2 = pose.landmarks[t2];
        if (l1 != null && l2 != null) {
          canvas.drawLine(
            Offset(l1.x * scaleX, l1.y * scaleY),
            Offset(l2.x * scaleX, l2.y * scaleY),
            linePaint,
          );
        }
      }

      // skeleton connections
      paintLine(PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder);
      paintLine(PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow);
      paintLine(PoseLandmarkType.rightShoulder, PoseLandmarkType.rightElbow);
      paintLine(PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist);
      paintLine(PoseLandmarkType.rightElbow, PoseLandmarkType.rightWrist);
      paintLine(PoseLandmarkType.leftShoulder, PoseLandmarkType.leftHip);
      paintLine(PoseLandmarkType.rightShoulder, PoseLandmarkType.rightHip);
      paintLine(PoseLandmarkType.leftHip, PoseLandmarkType.rightHip);
      paintLine(PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee);
      paintLine(PoseLandmarkType.rightHip, PoseLandmarkType.rightKnee);
      paintLine(PoseLandmarkType.leftKnee, PoseLandmarkType.leftAnkle);
      paintLine(PoseLandmarkType.rightKnee, PoseLandmarkType.rightAnkle);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}