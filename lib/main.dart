import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_vision/flutter_vision.dart';
import 'package:camera/camera.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'map_screen.dart';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'cloud_service.dart';
import 'auth_screen.dart';
import 'admin_dashboard_screen.dart';
import 'profile_screen.dart';
import 'app_settings.dart';
import 'app_design.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

late List<CameraDescription> cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    print('Firebase initialization error: $e');
  }
  cameras = [];
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppSettings.instance.themeModeNotifier,
      builder: (context, themeMode, _) {
        return MaterialApp(
          title: 'Pothole Scanner & Admin Web',
          debugShowCheckedModeBanner: false,
          themeMode: themeMode,
          theme: AppDesign.buildTheme(isDark: false),
          darkTheme: AppDesign.buildTheme(isDark: true),
          home: StreamBuilder(
            stream: CloudService.instance.authStateChanges,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              }
              final user = snapshot.data;
              if (user == null) {
                return AuthScreen(onAuthSuccess: () {});
              }
              return FutureBuilder<String>(
                future: CloudService.instance.getUserRole(user.uid),
                builder: (context, roleSnapshot) {
                  if (roleSnapshot.connectionState == ConnectionState.waiting) {
                    return const Scaffold(
                      body: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final role = roleSnapshot.data ?? 'user';
                  if (kIsWeb && (role == 'admin' || role == 'super_admin')) {
                    return const AdminDashboardScreen();
                  }
                  return const MyHomePage(title: 'Pothole Scanner');
                },
              );
            },
          ),
        );
      },
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});
  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final ImagePicker _picker = ImagePicker();

  bool _isModelLoaded = false;
  FlutterVision? vision;

  CameraController? _cameraController;
  bool _isDetecting = false;
  Timer? _detectionTimer;

  // State Management
  final GlobalKey<MapScreenState> _mapScreenKey = GlobalKey<MapScreenState>();
  bool _isRealtimeMode = false;
  int _currentIndex = 0;
  List<PotholeMarker> _detectedPotholes = [];
  bool _isSending = false;
  final FlutterTts _flutterTts = FlutterTts();
  StreamSubscription<Position>? _positionStream;

  // Realtime state
  final ValueNotifier<List<Map<String, dynamic>>?> _cameraRecognitionsNotifier = ValueNotifier(null);
  int _cameraImageHeight = 0;
  int _cameraImageWidth = 0;

  // Static image state
  File? _staticImage;
  List<Map<String, dynamic>>? _staticRecognitions;
  int _staticImageHeight = 0;
  int _staticImageWidth = 0;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      vision = FlutterVision();
      _initTTS();
      _loadModel();
    }
    _loadPotholesFromDB();
  }

  Future<void> _initTTS() async {
    await _flutterTts.setLanguage("en-US");
    await _flutterTts.setPitch(1.0);
    await _flutterTts.setSpeechRate(0.5);
  }

  void _loadPotholesFromDB() {
    try {
      CloudService.instance.streamAllPotholes().listen((snapshot) {
        final currentUser = CloudService.instance.currentUser;
        final cloudPotholes = <PotholeMarker>[];
        for (final doc in snapshot.docs) {
          try {
            final data = doc.data() as Map<String, dynamic>?;
            if (data == null) continue;
            final latNum = data['latitude'];
            final lngNum = data['longitude'];
            if (latNum == null || lngNum == null) continue;
            final lat = (latNum is num)
                ? latNum.toDouble()
                : double.tryParse(latNum.toString());
            final lng = (lngNum is num)
                ? lngNum.toDouble()
                : double.tryParse(lngNum.toString());
            if (lat == null || lng == null) continue;

            final imageUrl = data['imageUrl'] as String? ?? '';
            final status =
                (data['status'] as String? ?? 'pending').toLowerCase().trim();
            final overallSeverity =
                (data['overallSeverity'] as String? ?? 'medium')
                    .toLowerCase()
                    .trim();
            final potholeCount = (data['potholeCount'] as num?)?.toInt() ?? 1;
            final reporterEmail =
                (data['reporterEmail'] as String? ?? '').trim();
            final reporterUid = (data['reporterUid'] as String? ?? '').trim();

            DateTime timestamp = DateTime.now();
            final rawTimestamp = data['timestamp'];
            if (rawTimestamp is Timestamp) {
              timestamp = rawTimestamp.toDate();
            } else if (rawTimestamp is int) {
              timestamp = DateTime.fromMillisecondsSinceEpoch(rawTimestamp);
            }

            // Exclude deleted and rejected reports
            if (status == 'deleted' || status == 'rejected') continue;

            // Include if approved live
            if (status == 'approved') {
              cloudPotholes.add(PotholeMarker(
                docId: doc.id,
                location: LatLng(lat, lng),
                imagePath: imageUrl,
                timestamp: timestamp,
                status: status,
                overallSeverity: overallSeverity,
                potholeCount: potholeCount,
                reporterEmail: reporterEmail,
                reporterUid: reporterUid,
              ));
              continue;
            }

            // Include if pending report owned by current user
            if (currentUser != null) {
              final isMyUid =
                  reporterUid.isNotEmpty && reporterUid == currentUser.uid;
              final isMyEmail = reporterEmail.isNotEmpty &&
                  currentUser.email != null &&
                  reporterEmail.toLowerCase() ==
                      currentUser.email!.toLowerCase().trim();
              if (isMyUid || isMyEmail) {
                cloudPotholes.add(PotholeMarker(
                  docId: doc.id,
                  location: LatLng(lat, lng),
                  imagePath: imageUrl,
                  timestamp: timestamp,
                  status: status,
                  overallSeverity: overallSeverity,
                  potholeCount: potholeCount,
                  reporterEmail: reporterEmail,
                  reporterUid: reporterUid,
                ));
              }
            }
          } catch (docErr) {
            debugPrint('Skipping malformed pothole doc ${doc.id}: $docErr');
          }
        }

        if (mounted) {
          setState(() {
            _detectedPotholes = cloudPotholes;
          });
          debugPrint("Loaded ${cloudPotholes.length} potholes from Firebase");
        }
      }, onError: (e) {
        debugPrint("Error in streamAllPotholes: $e");
      });
    } catch (e) {
      debugPrint("Error loading Firebase potholes: $e");
    }
  }

  Future<void> _deleteDetectedPothole(PotholeMarker pothole) async {
    try {
      if (pothole.docId != null) {
        await CloudService.instance.deletePothole(pothole.docId!);
      } else {
        throw Exception('Marker not found in cloud database.');
      }

      if (pothole.imagePath.isNotEmpty) {
        final file = File(pothole.imagePath);
        if (file.existsSync()) {
          file.deleteSync();
        }
      }

      _loadPotholesFromDB();
    } catch (e) {
      print('Delete pothole error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not delete pothole marker.'),
          backgroundColor: AppDesign.danger,
        ),
      );
    }
  }

  Future<void> _addMarkerFromMap(LatLng location) async {
    String docId = 'local_${DateTime.now().millisecondsSinceEpoch}';
    try {
      final docRef = await CloudService.instance.addPotholeToCloud(
        location: location,
        imageUrl: '',
        overallSeverity: 'medium',
        potholeCount: 1,
      );
      docId = docRef.id;
    } catch (e) {
      print('Cloud write note (local fallback used for manual dev marker): $e');
    }
    final newMarker = PotholeMarker(
      docId: docId,
      location: location,
      imagePath: '',
      timestamp: DateTime.now(),
      status: 'approved',
      overallSeverity: 'medium',
      potholeCount: 1,
      reporterUid: CloudService.instance.currentUser?.uid ?? 'dev_user',
      reporterEmail:
          CloudService.instance.currentUser?.email ?? 'dev@roadsense.local',
    );
    if (mounted) {
      setState(() {
        _detectedPotholes.add(newMarker);
      });
    }
  }

  void _onTabSelected(int index) {
    if (_currentIndex == index) return;
    if (index != 1 && _isRealtimeMode) {
      _stopRealtime();
    }
    setState(() => _currentIndex = index);
  }

  Future<void> _stopRealtime() async {
    _isRealtimeMode = false;
    _isDetecting = false;
    _detectionTimer?.cancel();
    _detectionTimer = null;
    _cameraRecognitionsNotifier.value = null;
    final controller = _cameraController;
    _cameraController = null;
    if (controller != null) {
      try {
        if (controller.value.isStreamingImages) {
          await controller.stopImageStream();
        }
      } catch (_) {}
      try {
        await controller.dispose();
      } catch (_) {}
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _initCamera() async {
    if (cameras.isEmpty && !kIsWeb) {
      try {
        cameras = await availableCameras();
      } catch (e) {
        print('Error querying available cameras: $e');
        cameras = [];
      }
    }
    if (cameras.isEmpty) return;
    try {
      if (_cameraController != null) {
        try {
          if (_cameraController!.value.isStreamingImages) {
            await _cameraController!.stopImageStream();
          }
          await _cameraController!.dispose();
        } catch (_) {}
        _cameraController = null;
      }
      _cameraController = CameraController(
        cameras[0],
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await _cameraController!.initialize();
      if (!mounted) return;
      setState(() {});
    } catch (e) {
      print("Camera init error: $e");
      _cameraController = null;
    }
  }

  Future<void> _loadModel() async {
    if (_isModelLoaded) return;
    try {
      await vision!.loadYoloModel(
        labels: 'assets/labels.txt',
        modelPath: 'assets/pothole_yolov8s_100epoch/best_float32.tflite',
        modelVersion: "yolov8",
        quantization: false,
        numThreads: 2,
        useGpu: false,
      );
      print("[YOLO] AI Model loaded successfully: YOLOv8s 100-Epoch (assets/pothole_yolov8s_100epoch/best_float32.tflite)");
      if (mounted) {
        setState(() {
          _isModelLoaded = true;
        });
      }
    } catch (e) {
      print("[YOLO] YOLOv8s 100-Epoch load error: $e. Trying YOLOv8s Float16...");
      try {
        await vision!.loadYoloModel(
          labels: 'assets/labels.txt',
          modelPath: 'assets/pothole_yolov8s_100epoch/best_float16.tflite',
          modelVersion: "yolov8",
          quantization: false,
          numThreads: 2,
          useGpu: false,
        );
        print("[YOLO] AI Model loaded successfully: YOLOv8s Float16 (assets/pothole_yolov8s_100epoch/best_float16.tflite)");
        if (mounted) {
          setState(() {
            _isModelLoaded = true;
          });
        }
      } catch (e2) {
        print("[YOLO] Float16 model error: $e2. Trying best_saved_model...");
        try {
          await vision!.loadYoloModel(
            labels: 'assets/labels.txt',
            modelPath: 'assets/best_saved_model/best_float32.tflite',
            modelVersion: "yolov8",
            quantization: false,
            numThreads: 2,
            useGpu: false,
          );
          print("[YOLO] AI Model loaded successfully: best_saved_model/best_float32.tflite");
          if (mounted) {
            setState(() {
              _isModelLoaded = true;
            });
          }
        } catch (e3) {
          print("[YOLO] All AI model load attempts failed: $e3");
        }
      }
    }
  }

  Future<void> _pickImage() async {
    try {
      if (!_isModelLoaded && !kIsWeb) {
        await _loadModel();
      }
      final XFile? photo = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 75,
      );
      if (photo != null) {
        if (_isRealtimeMode) await _toggleRealtime();

        setState(() {
          _staticImage = File(photo.path);
          _staticRecognitions = null;
        });
        await _detectPotholeOnStatic(photo.path);
      }
    } catch (e) {
      print("Error picking picture: $e");
    }
  }

  Future<void> _toggleRealtime() async {
    if (_isRealtimeMode) {
      await _stopRealtime();
    } else {
      if (!_isModelLoaded && !kIsWeb) {
        await _loadModel();
      }
      await _initCamera();
      if (_cameraController == null ||
          !_cameraController!.value.isInitialized) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Camera unavailable or permission denied.'),
            ),
          );
        }
        return;
      }

      setState(() {
        _isRealtimeMode = true;
        _staticImage = null;
        _cameraRecognitionsNotifier.value = null;
      });

      // Use timer-based takePicture() + yoloOnImage instead of raw YUV stream.
      // This bypasses Android YUV plane stride-padding bugs and always produces
      // a correctly-oriented, properly-encoded image for inference.
      _detectionTimer?.cancel();
      _detectionTimer = Timer.periodic(const Duration(milliseconds: 900), (timer) async {
        if (!_isRealtimeMode || _cameraController == null) {
          timer.cancel();
          return;
        }
        if (_isDetecting) return;
        _isDetecting = true;
        XFile? photo;
        try {
          photo = await _cameraController!.takePicture();
          final bytes = await photo.readAsBytes();
          final decodedImage = await decodeImageFromList(bytes);

          if (!_isModelLoaded) {
            print('[YOLO LIVE] Model not loaded yet, skipping frame');
            return;
          }

          final result = await vision!.yoloOnImage(
            bytesList: bytes,
            imageHeight: decodedImage.height,
            imageWidth: decodedImage.width,
            iouThreshold: 0.40,
            confThreshold: 0.12,
            classThreshold: 0.12,
          );

          if (mounted && _isRealtimeMode) {
            _cameraImageHeight = decodedImage.height;
            _cameraImageWidth = decodedImage.width;
            _cameraRecognitionsNotifier.value = result.isEmpty ? null : result;
            if (result.isNotEmpty) {
              print('[YOLO LIVE] ${result.length} detections: $result');
            }
          }
        } catch (e) {
          print('[YOLO LIVE ERROR] $e');
        } finally {
          // Clean up the temp photo file
          if (photo != null) {
            try { File(photo.path).deleteSync(); } catch (_) {}
          }
          _isDetecting = false;
        }
      });
    }
  }

  Future<void> _captureFromStream() async {
    if (!_isRealtimeMode) return;
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }

    // 1. Cancel the periodic detection timer immediately
    _detectionTimer?.cancel();
    _detectionTimer = null;

    // 2. Wait up to 1 second if a frame inference is currently in-flight to avoid camera busy errors
    int waits = 0;
    while (_isDetecting && waits < 10) {
      await Future.delayed(const Duration(milliseconds: 100));
      waits++;
    }
    _isDetecting = false;

    // Preserve the current live detections so user doesn't lose highlighted boxes
    final liveRecs = _cameraRecognitionsNotifier.value;

    try {
      final XFile photo = await _cameraController!.takePicture();

      if (mounted) {
        setState(() {
          _isRealtimeMode = false;
          _staticImage = File(photo.path);
          _staticRecognitions = liveRecs;
          _cameraRecognitionsNotifier.value = null;
        });
      }

      await _detectPotholeOnStatic(photo.path);
    } catch (e) {
      print('[YOLO] Capture error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to capture photo: $e'),
            backgroundColor: AppDesign.danger,
          ),
        );
      }
    }
  }

  Future<void> _detectPotholeOnStatic(String imagePath) async {
    if (!_isModelLoaded) {
      await _loadModel();
    }
    if (!_isModelLoaded) return;

    try {
      Uint8List bytes = await File(imagePath).readAsBytes();
      final decodedImage = await decodeImageFromList(bytes);

      if (mounted) {
        setState(() {
          _staticImageHeight = decodedImage.height;
          _staticImageWidth = decodedImage.width;
        });
      }

      final result = await vision!.yoloOnImage(
        bytesList: bytes,
        imageHeight: decodedImage.height,
        imageWidth: decodedImage.width,
        iouThreshold: 0.45,
        confThreshold: 0.12,
        classThreshold: 0.12,
      );

      print("[YOLO STATIC] ${result.length} potholes detected: $result");

      if (mounted) {
        setState(() {
          if (result.isNotEmpty || _staticRecognitions == null || _staticRecognitions!.isEmpty) {
            _staticRecognitions = result;
          }
        });
      }
    } catch (e) {
      print("Error running static model: $e");
    }
  }

  /// Extracts the model-predicted severity tag ('low', 'medium', 'high') directly from TFLite output
  static String getDetectionSeverity(Map<String, dynamic> det) {
    final String tag = (det['tag'] as String? ?? '').trim().toLowerCase();
    if (tag.contains('high') || tag.contains('major')) return 'high';
    if (tag.contains('med')) return 'medium';
    if (tag.contains('low') || tag.contains('minor')) return 'low';

    // Dynamic heuristic for single-class 'pothole' model using bounding box area & confidence
    if (det.containsKey('box')) {
      final box = det['box'] as List<dynamic>;
      if (box.length >= 4) {
        final left = (box[0] as num).toDouble();
        final top = (box[1] as num).toDouble();
        final right = (box[2] as num).toDouble();
        final bottom = (box[3] as num).toDouble();
        final double width = (right - left).abs();
        final double height = (bottom - top).abs();
        final double area = width * height;
        final double conf = box.length > 4 ? (box[4] as num).toDouble() : 0.5;

        if (area > 45000 || conf >= 0.78) return 'high';
        if (area > 12000 || conf >= 0.42) return 'medium';
        return 'low';
      }
    }
    return 'medium';
  }

  static Color getSeverityColor(String severity) {
    switch (severity.toLowerCase()) {
      case 'high':
        return const Color(0xFFEF4444); // 🔴 High Severity (Red)
      case 'medium':
        return const Color(0xFFF97316); // 🟠 Medium Severity (Orange)
      case 'low':
      default:
        return const Color(0xFFEAB308); // 🟡 Low Severity (Amber)
    }
  }

  /// Maps detection attributes to DPWH standard highway defect codes
  static String getDpwhCode(String severity, [String tag = '']) {
    final lowerTag = tag.toLowerCase();
    if (lowerTag.contains('alligator') || lowerTag.contains('crocodile')) return 'CODE 02';
    if (lowerTag.contains('depression') || lowerTag.contains('rut')) return 'CODE 05';
    if (lowerTag.contains('crack') || lowerTag.contains('transverse') || lowerTag.contains('longitudinal')) return 'CODE 12';
    switch (severity.toLowerCase()) {
      case 'high':
        return 'CODE 01';
      case 'medium':
        return 'CODE 02';
      case 'low':
      default:
        return 'CODE 05';
    }
  }

  /// Human-readable title for DPWH maintenance categorization
  static String getDpwhDefectTitle(String code) {
    switch (code) {
      case 'CODE 01':
        return 'Pothole (Urgent 3-Day)';
      case 'CODE 02':
        return 'Alligator Crack (High 3-Day)';
      case 'CODE 05':
        return 'Pavement Depression (30-Day)';
      case 'CODE 12':
        return 'Crack (Routine Sealant)';
      default:
        return 'Pothole';
    }
  }

  /// Evaluates the highest severity among all detected potholes in the image
  static String getOverallSeverity(List<Map<String, dynamic>> detections) {
    if (detections.isEmpty) return 'medium';
    bool hasHigh = false;
    bool hasMed = false;
    for (final det in detections) {
      final sev = getDetectionSeverity(det);
      if (sev == 'high') hasHigh = true;
      if (sev == 'medium') hasMed = true;
    }
    if (hasHigh) return 'high';
    if (hasMed) return 'medium';
    return 'low';
  }

  /// Counts the total detections broken down by severity
  static Map<String, int> getSeverityCounts(
      List<Map<String, dynamic>> detections) {
    int highCount = 0;
    int medCount = 0;
    int lowCount = 0;
    for (final det in detections) {
      final sev = getDetectionSeverity(det);
      if (sev == 'high') {
        highCount++;
      } else if (sev == 'medium') {
        medCount++;
      } else {
        lowCount++;
      }
    }
    return {'high': highCount, 'medium': medCount, 'low': lowCount};
  }

  /// Robust location getter that checks permissions and falls back to last known position
  Future<Position?> _getCurrentLocation() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return await Geolocator.getLastKnownPosition();
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          return await Geolocator.getLastKnownPosition();
        }
      }

      if (permission == LocationPermission.deniedForever) {
        return await Geolocator.getLastKnownPosition();
      }

      try {
        return await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 4),
          ),
        );
      } catch (_) {
        final lastKnown = await Geolocator.getLastKnownPosition();
        if (lastKnown != null) return lastKnown;
        return await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.low,
            timeLimit: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      print('Location fetch error: $e');
      try {
        return await Geolocator.getLastKnownPosition();
      } catch (_) {
        return null;
      }
    }
  }

  Future<void> _sendToMap() async {
    if (_staticImage == null) return;
    setState(() => _isSending = true);

    try {
      // 1. Obtain GPS Location
      Position? position = await _getCurrentLocation();
      final LatLng loc = position != null
          ? LatLng(position.latitude, position.longitude)
          : const LatLng(14.5995, 120.9842); // Default fallback coordinate

      // 2. Save annotated image with bounding boxes
      final detections = _staticRecognitions ?? [];
      String savedPath;
      try {
        savedPath = await _saveAnnotatedImage(
          imageFile: _staticImage!,
          detections: detections,
          imgWidth: _staticImageWidth > 0 ? _staticImageWidth : 640,
          imgHeight: _staticImageHeight > 0 ? _staticImageHeight : 640,
        );
      } catch (e) {
        print("Annotated image save error, using original photo: $e");
        savedPath = _staticImage!.path;
      }

      // 3. Upload photo to Azure Storage
      String? azureUrl;
      try {
        final file = File(savedPath);
        if (file.existsSync()) {
          final bytes = await file.readAsBytes();
          azureUrl = await CloudService.instance.uploadImageBytesToAzure(bytes);
          print("[UPLOAD] Azure upload completed: $azureUrl");
        }
      } catch (e) {
        print("[UPLOAD] Azure upload error: $e");
      }

      // 4. Save pothole report to Firestore
      final overallSeverity = getOverallSeverity(detections);
      final potholeCount = detections.isNotEmpty ? detections.length : 1;

      final List<Map<String, dynamic>> parsedDetections = detections.map((det) {
        if (!det.containsKey('box')) return <String, dynamic>{};
        final box = det['box'] as List<dynamic>;
        final left = (box[0] as num).toDouble();
        final top = (box[1] as num).toDouble();
        final right = (box[2] as num).toDouble();
        final bottom = (box[3] as num).toDouble();
        final conf = box.length > 4 ? (box[4] as num).toDouble() : 0.0;
        final sev = getDetectionSeverity(det);
        final dpwhCode = getDpwhCode(sev, det['tag'] as String? ?? '');
        final defectType = getDpwhDefectTitle(dpwhCode);
        return {
          'severity': sev,
          'confidence': conf,
          'dpwhCode': dpwhCode,
          'defectType': defectType,
          'box': [left, top, right, bottom],
        };
      }).toList();

      await CloudService.instance.addPotholeToCloud(
        location: loc,
        imageUrl: azureUrl ?? '',
        overallSeverity: overallSeverity,
        potholeCount: potholeCount,
        detections: parsedDetections,
      );

      _loadPotholesFromDB();

      if (mounted) {
        setState(() {
          _isSending = false;
          _staticImage = null;
          _staticRecognitions = null;
          _currentIndex = 0;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "✅ $potholeCount Pothole(s) (${overallSeverity.toUpperCase()} Severity) submitted for approval!",
            ),
            backgroundColor: getSeverityColor(overallSeverity),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      print("[UPLOAD] Error in _sendToMap: $e");
      if (mounted) {
        setState(() => _isSending = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("❌ Upload failed: $e"),
            backgroundColor: AppDesign.danger,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  Future<String> _saveAnnotatedImage({
    required File imageFile,
    required List<Map<String, dynamic>> detections,
    required int imgWidth,
    required int imgHeight,
  }) async {
    final rawBytes = await imageFile.readAsBytes();
    final codec = await ui.instantiateImageCodec(rawBytes);
    final frame = await codec.getNextFrame();
    final srcImage = frame.image;

    final double maxDim = 1280.0;
    double scale = 1.0;
    if (srcImage.width > maxDim || srcImage.height > maxDim) {
      if (srcImage.width > srcImage.height) {
        scale = maxDim / srcImage.width;
      } else {
        scale = maxDim / srcImage.height;
      }
    }

    final int targetWidth = (srcImage.width * scale).round();
    final int targetHeight = (srcImage.height * scale).round();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      Rect.fromLTWH(
        0,
        0,
        targetWidth.toDouble(),
        targetHeight.toDouble(),
      ),
    );

    canvas.scale(scale);
    canvas.drawImage(srcImage, Offset.zero, Paint());

    for (final det in detections) {
      if (!det.containsKey('box')) continue;
      final box = det['box'] as List<dynamic>;
      final left = (box[0] as num).toDouble();
      final top = (box[1] as num).toDouble();
      final right = (box[2] as num).toDouble();
      final bottom = (box[3] as num).toDouble();
      final conf = box.length > 4 ? (box[4] as num).toDouble() * 100 : 0.0;

      final String severity = getDetectionSeverity(det);
      final Color boxColor = getSeverityColor(severity);

      final boxPaint = Paint()
        ..color = boxColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = (srcImage.width / 200).clamp(2.0, 8.0);

      final bgPaint = Paint()..color = boxColor;

      canvas.drawRect(Rect.fromLTRB(left, top, right, bottom), boxPaint);

      final fontSize = (srcImage.width / 32).clamp(12.0, 36.0);
      final labelH = fontSize + 8;
      final labelW = fontSize * 7.5;
      canvas.drawRect(
        Rect.fromLTWH(left, top - labelH, labelW, labelH),
        bgPaint,
      );

      final tp = TextPainter(
        text: TextSpan(
          text: '${severity.toUpperCase()} • ${conf.toStringAsFixed(0)}%',
          style: TextStyle(
            color: Colors.white,
            fontSize: fontSize,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      tp.layout(maxWidth: labelW);
      tp.paint(canvas, Offset(left + 4, top - labelH + 3));
    }

    final picture = recorder.endRecording();
    final annotated = await picture.toImage(targetWidth, targetHeight);
    final byteData = await annotated.toByteData(format: ui.ImageByteFormat.png);
    final pngBytes = byteData!.buffer.asUint8List();

    final appDir = await getApplicationDocumentsDirectory();
    final potholeDir = Directory(p.join(appDir.path, 'potholes'));
    if (!potholeDir.existsSync()) potholeDir.createSync();
    final savedPath = p.join(
      potholeDir.path,
      'pothole_${DateTime.now().millisecondsSinceEpoch}.png',
    );
    await File(savedPath).writeAsBytes(pngBytes);
    return savedPath;
  }

  @override
  void dispose() {
    vision?.closeYoloModel();
    if (_cameraController != null) {
      _cameraController!.dispose();
    }
    super.dispose();
  }

  List<Widget> displayBoxesForCamera(
      Size screen, List<Map<String, dynamic>>? recs) {
    if (recs == null || recs.isEmpty) return [];
    if (_cameraImageWidth == 0 || _cameraImageHeight == 0) return [];

    // takePicture() produces a correctly-oriented portrait JPEG.
    // Scale boxes from photo pixel space to screen pixel space.
    final double srcW = _cameraImageWidth.toDouble();
    final double srcH = _cameraImageHeight.toDouble();

    final double scaleX = screen.width / (srcW > 0 ? srcW : 1.0);
    final double scaleY = screen.height / (srcH > 0 ? srcH : 1.0);

    return recs
        .map((result) => _buildBox(
              result,
              scaleX,
              scaleY,
            ))
        .toList();
  }

  List<Widget> displayBoxesForStatic(
    Size viewSize,
    List<Map<String, dynamic>>? recs,
  ) {
    if (recs == null || recs.isEmpty) return [];
    if (_staticImageWidth == 0 || _staticImageHeight == 0) return [];

    final double viewW = viewSize.width;
    final double viewH = viewSize.height;
    final double imgW = _staticImageWidth.toDouble();
    final double imgH = _staticImageHeight.toDouble();

    // Calculate scale and offset for BoxFit.cover
    final double scale = (viewW / imgW > viewH / imgH)
        ? (viewW / imgW)
        : (viewH / imgH);
    final double offsetX = (viewW - imgW * scale) / 2.0;
    final double offsetY = (viewH - imgH * scale) / 2.0;

    return recs.map((result) {
      if (!result.containsKey("box")) return const SizedBox.shrink();
      final box = result["box"] as List<dynamic>;
      final double left = offsetX + (box[0] as num).toDouble() * scale;
      final double top = offsetY + (box[1] as num).toDouble() * scale;
      final double right = offsetX + (box[2] as num).toDouble() * scale;
      final double bottom = offsetY + (box[3] as num).toDouble() * scale;
      final double width = right - left;
      final double height = bottom - top;
      final double confidence =
          box.length > 4 ? (box[4] as num).toDouble() * 100 : 0.0;

      final String severity = getDetectionSeverity(result);
      final String dpwhCode = getDpwhCode(severity, result['tag'] as String? ?? '');
      final Color boxColor = getSeverityColor(severity);
      final String severityLabel = severity.toUpperCase();

      return Positioned(
        left: left,
        top: top,
        width: width,
        height: height,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(Radius.circular(10.0)),
            border: Border.all(color: boxColor, width: 3.0),
          ),
          child: Align(
            alignment: Alignment.topLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: boxColor,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(6),
                  bottomRight: Radius.circular(6),
                ),
              ),
              child: Text(
                '[$dpwhCode] $severityLabel ${confidence > 0 ? "(${confidence.toStringAsFixed(0)}%)" : ""}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
      );
    }).toList();
  }

  Widget _buildBox(
    Map<String, dynamic> result,
    double scaleX,
    double scaleY,
  ) {
    if (!result.containsKey("box")) return const SizedBox.shrink();

    List<dynamic> box = result["box"];
    double left = box[0] * scaleX;
    double top = box[1] * scaleY;
    double right = box[2] * scaleX;
    double bottom = box[3] * scaleY;
    double width = right - left;
    double height = bottom - top;
    double confidence = box.length > 4 ? box[4] * 100 : 0.0;

    final String severity = getDetectionSeverity(result);
    final String dpwhCode = getDpwhCode(severity, result['tag'] as String? ?? '');
    final Color boxColor = getSeverityColor(severity);
    final String severityLabel = severity.toUpperCase();

    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.all(Radius.circular(10.0)),
          border: Border.all(color: boxColor, width: 3.0),
        ),
        child: Align(
          alignment: Alignment.topLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: boxColor,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(6),
                bottomRight: Radius.circular(8),
              ),
            ),
            child: Text(
              "[$dpwhCode] $severityLabel • ${confidence.toStringAsFixed(0)}%",
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12.0,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return Scaffold(
        body: IndexedStack(
          index: _currentIndex == 0
              ? 0
              : (_currentIndex > 1 ? 1 : _currentIndex),
          children: [
            MapScreen(
              key: _mapScreenKey,
              detectedPotholes: _detectedPotholes,
              onDeleteDetectedPothole: _deleteDetectedPothole,
              onAddDetectedPothole: _addMarkerFromMap,
              onOpenProfile: () => setState(() => _currentIndex = 1),
              isMapActive: _currentIndex == 0,
            ),
            ProfileScreen(
              onSwitchToMap: () => setState(() => _currentIndex = 0),
              onLocateOnMap: (location, docId, data) {
                setState(() => _currentIndex = 0);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _mapScreenKey.currentState?.locatePothole(location, docId, data);
                });
              },
              onLocateAllOnMap: (locations, {String filterLabel = 'all'}) {
                setState(() => _currentIndex = 0);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _mapScreenKey.currentState?.locateAllPotholes(locations, filterLabel: filterLabel);
                });
              },
            ),
          ],
        ),
      );
    }

    final Size size = MediaQuery.of(context).size;

    Widget scannerOverlay = Container(
      color: AppDesign.bg(true),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _isRealtimeMode
                              ? AppDesign.danger
                              : AppDesign.accent(true),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _isRealtimeMode
                            ? 'LIVE SCANNER'
                            : (_staticImage != null
                                  ? 'REVIEW'
                                  : 'RIDER DASHCAM'),
                        style: TextStyle(
                          color: AppDesign.textSecondary(true),
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2,
                        ),
                      ),
                    ],
                  ),
                  if (!_isRealtimeMode)
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _currentIndex = 0;
                          _staticImage = null;
                          _staticRecognitions = null;
                        });
                      },
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.close,
                          color: AppDesign.textSecondary(true),
                          size: 22,
                        ),
                      ),
                    ),
                ],
              ),
            ),

            const SizedBox(height: 8),
            Divider(color: Colors.white.withValues(alpha: 0.08), thickness: 1),

            if (!_isRealtimeMode && _staticImage == null) ...[
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Matte Hero scanner icon
                      Container(
                        width: 96,
                        height: 96,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppDesign.surface(true),
                          border: Border.all(
                            color: const Color(0xFF334155),
                            width: 1.5,
                          ),
                        ),
                        child: Icon(
                          Icons.document_scanner_rounded,
                          size: 46,
                          color: AppDesign.accent(true),
                        ),
                      ),
                      const SizedBox(height: 28),
                      Text(
                        'AI Pothole\nDetection',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 30,
                          fontWeight: FontWeight.w900,
                          height: 1.15,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Tap START SCANNER to begin real-time\nAI-powered detection.',
                        style: TextStyle(
                          color: AppDesign.textSecondary(true).withValues(alpha: 0.7),
                          fontSize: 13.5,
                          height: 1.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 44),
                      SizedBox(
                        width: double.infinity,
                        height: 60,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppDesign.accent(true),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          onPressed: _toggleRealtime,
                          icon: const Icon(Icons.radar_rounded, size: 24),
                          label: const Text(
                            'START SCANNER',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.0,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        height: 54,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppDesign.textSecondary(true),
                            side: BorderSide(
                              color: Colors.white.withValues(alpha: 0.10),
                              width: 1,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          onPressed: _pickImage,
                          icon: const Icon(
                            Icons.photo_camera_outlined,
                            size: 22,
                          ),
                          label: const Text(
                            'Take Manual Photo',
                            style: TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ] else if (_isRealtimeMode) ...[
              Expanded(
                // LayoutBuilder gives the ACTUAL camera-preview area size,
                // which is smaller than MediaQuery.size (excludes header + capture bar).
                // Using the wrong (full-screen) size inflates scaleY and shifts
                // every bounding box downward.
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final cameraViewSize = Size(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    return Stack(
                      children: [
                        if (_cameraController != null &&
                            _cameraController!.value.isInitialized)
                          Positioned.fill(
                              child: CameraPreview(_cameraController!)),
                        ValueListenableBuilder<List<Map<String, dynamic>>?>(
                          valueListenable: _cameraRecognitionsNotifier,
                          builder: (context, recs, _) {
                            return Stack(
                              children: [
                                if (_cameraController != null &&
                                    _cameraController!.value.isInitialized)
                                  ...displayBoxesForCamera(cameraViewSize, recs),
                                Positioned(
                                  top: 12,
                                  left: 16,
                                  right: 16,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 10,
                                      horizontal: 14,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppDesign.bg(true)
                                          .withValues(alpha: 0.88),
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color:
                                            Colors.white.withValues(alpha: 0.08),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Row(
                                          children: [
                                            Container(
                                              width: 10,
                                              height: 10,
                                              decoration: const BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: AppDesign.danger,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              recs != null && recs.isNotEmpty
                                                  ? '${recs.length} DETECTED'
                                                  : 'SCANNING...',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 14,
                                                fontWeight: FontWeight.w800,
                                                letterSpacing: 1.2,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF0284C7).withValues(alpha: 0.85),
                                                borderRadius: BorderRadius.circular(12),
                                              ),
                                              child: const Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(Icons.directions_walk_rounded, color: Colors.white, size: 12),
                                                  SizedBox(width: 3),
                                                  Text(
                                                    'ON FOOT',
                                                    style: TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 9,
                                                      fontWeight: FontWeight.w800,
                                                      letterSpacing: 0.5,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                        GestureDetector(
                                          onTap: () {
                                            _toggleRealtime();
                                            setState(
                                                () => _currentIndex = 0);
                                          },
                                          child: Container(
                                            width: 36,
                                            height: 36,
                                            decoration: BoxDecoration(
                                              color: Colors.white
                                                  .withValues(alpha: 0.15),
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            child: Icon(
                                              Icons.close,
                                              color:
                                                  AppDesign.textPrimary(true),
                                              size: 20,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                // Walking Survey Alignment Reticle (Center Guide)
                                if (recs == null || recs.isEmpty)
                                  Center(
                                    child: IgnorePointer(
                                      child: Container(
                                        width: 220,
                                        height: 220,
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: Colors.white.withValues(alpha: 0.28),
                                            width: 1.5,
                                          ),
                                          borderRadius: BorderRadius.circular(16),
                                        ),
                                        child: Column(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Padding(
                                              padding: const EdgeInsets.only(top: 8),
                                              child: Text(
                                                'ALIGN ROAD SURFACE',
                                                style: TextStyle(
                                                  color: Colors.white.withValues(alpha: 0.7),
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.w700,
                                                  letterSpacing: 1,
                                                ),
                                              ),
                                            ),
                                            Icon(
                                              Icons.control_camera_rounded,
                                              color: Colors.white.withValues(alpha: 0.25),
                                              size: 32,
                                            ),
                                            Padding(
                                              padding: const EdgeInsets.only(bottom: 8),
                                              child: Text(
                                                'WALK & HOLD STEADY',
                                                style: TextStyle(
                                                  color: Colors.white.withValues(alpha: 0.7),
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.w700,
                                                  letterSpacing: 1,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                      ],
                    );
                  },
                ),
              ),
              Container(
                color: AppDesign.bg(true),
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                child: SizedBox(
                  width: double.infinity,
                  height: 72,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppDesign.danger,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                    onPressed: _captureFromStream,
                    icon: const Icon(Icons.camera_alt_rounded, size: 28),
                    label: const Text(
                      'CAPTURE DISTRESS',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                ),
              ),
            ] else if (_staticImage != null) ...[
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final viewSize = Size(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    return Stack(
                      children: [
                        Positioned.fill(
                          child: Image.file(_staticImage!, fit: BoxFit.cover),
                        ),
                        ...displayBoxesForStatic(viewSize, _staticRecognitions),
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: Container(
                            height: 80,
                            decoration: const BoxDecoration(
                              color: Color(0x990F172A),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 30),
                decoration: BoxDecoration(
                  color: AppDesign.bg(true),
                  border: Border(
                    top: BorderSide(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Builder(
                      builder: (context) {
                        final hasDetections = _staticRecognitions != null &&
                            _staticRecognitions!.isNotEmpty;
                        if (!hasDetections) {
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.1),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.info_outline_rounded,
                                  color: AppDesign.textSecondary(true),
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Manual Report • Ready to Upload',
                                  style: TextStyle(
                                    color: AppDesign.textSecondary(true),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14.5,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }

                        final overallSev =
                            getOverallSeverity(_staticRecognitions!);
                        final sevCounts =
                            getSeverityCounts(_staticRecognitions!);
                        final Color sevColor = getSeverityColor(overallSev);

                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: sevColor.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: sevColor.withValues(alpha: 0.6),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.warning_rounded,
                                    color: sevColor,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '${_staticRecognitions!.length} Pothole(s) • ${overallSev.toUpperCase()} SEVERITY',
                                    style: TextStyle(
                                      color: sevColor,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 14.5,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (_staticRecognitions!.length > 1) ...[
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 4,
                                alignment: WrapAlignment.center,
                                children: [
                                  if (sevCounts['high']! > 0)
                                    _buildSeverityCountChip(
                                      label: '${sevCounts['high']} High',
                                      color: const Color(0xFFEF4444),
                                    ),
                                  if (sevCounts['medium']! > 0)
                                    _buildSeverityCountChip(
                                      label: '${sevCounts['medium']} Medium',
                                      color: const Color(0xFFF97316),
                                    ),
                                  if (sevCounts['low']! > 0)
                                    _buildSeverityCountChip(
                                      label: '${sevCounts['low']} Low',
                                      color: const Color(0xFFEAB308),
                                    ),
                                ],
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      height: 64,
                      child: ElevatedButton.icon(
                        onPressed: _isSending ? null : _sendToMap,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppDesign.accent(true),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        icon: _isSending
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 3,
                                ),
                              )
                            : const Icon(Icons.cloud_upload_rounded, size: 26),
                        label: Text(
                          _isSending ? 'UPLOADING...' : 'SEND TO MAP',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: OutlinedButton.icon(
                        onPressed: () => setState(() {
                          _staticImage = null;
                          _staticRecognitions = null;
                        }),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppDesign.textSecondary(true),
                          side: BorderSide(
                            color: Colors.white.withValues(alpha: 0.10),
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        icon: const Icon(Icons.replay_rounded, size: 20),
                        label: const Text(
                          'Retake Photo',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );

    return Scaffold(
      extendBody: true,
      body: IndexedStack(
        index: _currentIndex,
        children: [
          MapScreen(
            key: _mapScreenKey,
            detectedPotholes: _detectedPotholes,
            onDeleteDetectedPothole: _deleteDetectedPothole,
            onAddDetectedPothole: _addMarkerFromMap,
            onOpenProfile: () => setState(() => _currentIndex = 2),
            isMapActive: _currentIndex == 0,
          ),
          scannerOverlay,
          ProfileScreen(
            onSwitchToMap: () => setState(() => _currentIndex = 0),
            onLocateOnMap: (location, docId, data) {
              setState(() => _currentIndex = 0);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _mapScreenKey.currentState?.locatePothole(location, docId, data);
              });
            },
            onLocateAllOnMap: (locations, {String filterLabel = 'all'}) {
              setState(() => _currentIndex = 0);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _mapScreenKey.currentState?.locateAllPotholes(locations, filterLabel: filterLabel);
              });
            },
          ),
        ],
      ),
      bottomNavigationBar: ValueListenableBuilder<bool>(
        valueListenable: AppSettings.instance.isRouteActiveNotifier,
        builder: (context, isRouteActive, child) {
          if (isRouteActive) return const SizedBox.shrink();
          return SafeArea(
            child: Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              height: 72,
              decoration: BoxDecoration(
                color: AppDesign.surface(AppSettings.instance.isDarkMode),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(color: AppDesign.border(AppSettings.instance.isDarkMode), width: 1),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 20,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildNavItem(
                    icon: Icons.route_rounded,
                    label: 'Navigate',
                    index: 0,
                    activeColor: AppDesign.accent(AppSettings.instance.isDarkMode),
                  ),
                  _buildScanItem(),
                  _buildNavItem(
                    icon: Icons.fact_check_rounded,
                    label: 'Reports',
                    index: 2,
                    activeColor: AppDesign.warning,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildNavItem({
    required IconData icon,
    required String label,
    required int index,
    Color? activeColor,
  }) {
    final bool isDark = AppSettings.instance.isDarkMode;
    final bool isActive = _currentIndex == index;
    final color = activeColor ?? AppDesign.accent(isDark);
    return GestureDetector(
      onTap: () => _onTabSelected(index),
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: isActive
                  ? color.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(
              icon,
              size: 21,
              color: isActive ? color : AppDesign.textSecondary(isDark),
            ),
          ),
          const SizedBox(height: 3),
          AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 200),
            style: TextStyle(
              fontSize: 10,
              fontWeight: isActive ? FontWeight.w800 : FontWeight.w500,
              color: isActive ? color : AppDesign.textSecondary(isDark),
              letterSpacing: 0.2,
            ),
            child: Text(label),
          ),
        ],
      ),
    );
  }

  Widget _buildScanItem() {
    final bool isActive = _currentIndex == 1;
    return GestureDetector(
      onTap: () => _onTabSelected(1),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: isActive ? AppDesign.textPrimary(false) : AppDesign.accent(false),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isActive ? Icons.radar_rounded : Icons.document_scanner_rounded,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 7),
            const Text(
              'SCAN',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSeverityCountChip({
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.7), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
