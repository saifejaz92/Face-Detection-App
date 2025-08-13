// identify_face_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:face_sdk_3divi/utils.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:face_sdk_3divi/face_sdk_3divi.dart'; // adjust if your package name differs

class IdentifyFaceScreen extends StatefulWidget {
  const IdentifyFaceScreen({Key? key}) : super(key: key);

  @override
  State<IdentifyFaceScreen> createState() => _IdentifyFaceScreenState();
}

class _IdentifyFaceScreenState extends State<IdentifyFaceScreen> with WidgetsBindingObserver {
  CameraController? _cameraController;
  List<CameraDescription>? _cameras;

  // 3DiVi objects
  late FacerecService _service;
  AsyncProcessingBlock? _faceDetector;
  AsyncProcessingBlock? _faceFitter;
  AsyncProcessingBlock? _templateExtractor;
  AsyncProcessingBlock? _verificationModule;

  bool _isProcessingFrame = false;
  String? _currentMatchName;
  double _currentScore = 0.0;

  // Stored templates: Map<uuid, {name, path, ContextTemplate?}>
  final Map<String, Map<String, dynamic>> _templatesIndex = {};

  // Threshold for declaring a match (tune on device)
  static const double MATCH_THRESHOLD = 0.70;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initAll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopCamera();
    _disposeFaceSdk();
    super.dispose();
  }

  // ---------- Initialization ----------

  Future<void> _initAll() async {
    try {
      // 1) Init camera
      _cameras = await availableCameras();
      if (_cameras == null || _cameras!.isEmpty) {
        throw Exception("No cameras found on device");
      }

      _cameraController = CameraController(
        _cameras!.first,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      await _cameraController!.initialize();

      // start stream
      await _cameraController!.startImageStream(_onCameraImage);

      // 2) Init FacerecService and processing blocks
      _service = await FaceSdkPlugin.createFacerecService();

      _faceDetector = await _service.createAsyncProcessingBlock({
        "unit_type": "FACE_DETECTOR",
        "modification": "blf_front"
      });

      _faceFitter = await _service.createAsyncProcessingBlock({
        "unit_type": "FACE_FITTER",
        "modification": "tddfa_faster"
      });

      _templateExtractor = await _service.createAsyncProcessingBlock({
        "unit_type": "FACE_TEMPLATE_EXTRACTOR",
        "modification": "30m" // mobile-optimized modification; use "30" or "1000" if you prefer
      });

      _verificationModule = await _service.createAsyncProcessingBlock({
        "unit_type": "VERIFICATION_MODULE",
        "modification": "30m"
      });

      // 3) Load saved templates from disk (and keep the ContextTemplate in memory)
      await _loadSavedTemplates();

      setState(() {});
    } catch (e, st) {
      debugPrint("Initialization error: $e\n$st");
      // Show alert to user
    }
  }

  Future<void> _loadSavedTemplates() async {
    // Expects a JSON file in app documents directory named templates_index.json with content like:
    // { "<uuid>": { "name": "Alice", "path": "templates/alice.bin" }, ... }
    final dir = await getApplicationDocumentsDirectory();
    final indexFile = File("${dir.path}/templates_index.json");
    if (!await indexFile.exists()) {
      debugPrint("No templates_index.json found, skipping template load.");
      return;
    }

    final jsonStr = await indexFile.readAsString();
    final Map<String, dynamic> jsonMap = json.decode(jsonStr);

    for (final entry in jsonMap.entries) {
      final uuid = entry.key;
      final name = entry.value['name'] as String?;
      final pathRelative = entry.value['path'] as String?;

      if (name == null || pathRelative == null) continue;

      final templateFile = File("${dir.path}/$pathRelative");
      if (!await templateFile.exists()) {
        debugPrint("Template file missing: ${templateFile.path}");
        continue;
      }

      final bytes = await templateFile.readAsBytes();

      try {
        // loadContextTemplate - creates ContextTemplate from raw bytes
        ContextTemplate ct = _service.loadContextTemplate(bytes);
        // store in map
        _templatesIndex[uuid] = {
          "name": name,
          "path": templateFile.path,
          "template": ct,
        };
        debugPrint("Loaded template for $name (uuid: $uuid)");
      } catch (e) {
        debugPrint("Failed to load template $uuid -> $e");
      }
    }
  }

  // ---------- Camera frame processing ----------

  void _onCameraImage(CameraImage image) async {
    if (_isProcessingFrame) return;
    if (_faceDetector == null || _faceFitter == null || _templateExtractor == null || _verificationModule == null) return;

    _isProcessingFrame = true;

    try {
      // Convert CameraImage -> NativeDataStruct bytes and create Context from frame
      NativeDataStruct nativeData = NativeDataStruct();
      ContextFormat format;

      // Helper from 3DiVi docs: convertRAW (we must use service.createContextFromFrame which accepts nativeData)
      // The package provides helpers; using createContextFromFrame below:
      if (image.format.group == ImageFormatGroup.yuv420) {
        // convert planes to a single bytes buffer using provided helper in SDK
        convertRAW(image.planes, nativeData);
        format = ContextFormat.FORMAT_YUV420;
      } else if (image.format.group == ImageFormatGroup.bgra8888) {
        // unlikely for mobile camera stream, but included for completeness
        convertRAW(image.planes, nativeData);
        format = ContextFormat.FORMAT_BGRA8888;
      } else {
        _isProcessingFrame = false;
        return;
      }

      // baseAngle: rotation of raw image in native terms (0=no rotate). For mobile camera we may need to pass rotation based on sensor orientation.
      // Here I pass 0 — if face appears rotated, compute correct baseAngle for your device/orientation.
      final int baseAngle = 0;

      Context data = _service.createContextFromFrame(
        nativeData.bytes!,
        image.width,
        image.height,
        format: format,
        baseAngle: baseAngle,
      );

      try {
        // Detect faces
        await _faceDetector!.process(data);

        final objectsLen = data["objects"].len();
        if (objectsLen == 0) {
          // no faces — clear match
          setState(() {
            _currentMatchName = null;
            _currentScore = 0.0;
          });
          data.dispose();
          _isProcessingFrame = false;
          return;
        }

        // We will handle single face scenario (if multiple you can loop through objects)
        if (objectsLen > 1) {
          // optional: you could handle multi-face by checking each and tracking bounding boxes
          // for simplicity we skip if more than one face in frame
        }

        // Fit landmarks
        await _faceFitter!.process(data);

        // Extract template (face template will be put into data["objects"][0]["face_template"]...)
        await _templateExtractor!.process(data);

        // Get the ContextTemplate object for the detected face
        var templObj = data["objects"][0]["face_template"]["template"];
        // In Flutter API this returns a ContextTemplate or wrapper; use get_value() as examples show
        ContextTemplate probeTemplate = templObj.get_value();

        // Now compare probeTemplate with all stored templates using verification module
        String? bestMatchName;
        double bestScore = 0.0;

        for (final kv in _templatesIndex.entries) {
          final stored = kv.value;
          final ctxTemplate = stored["template"] as ContextTemplate?;
          if (ctxTemplate == null) continue;

          // Build verification context with two templates
          Context verificationCtx = _service.createContext({
            "template1": probeTemplate,
            "template2": ctxTemplate,
          });

          try {
            await _verificationModule!.process(verificationCtx);

            final result = verificationCtx["result"];
            final score = result["score"].get_value() as double? ?? 0.0;
            // keep best
            if (score > bestScore) {
              bestScore = score;
              bestMatchName = stored["name"] as String;
            }
          } catch (e) {
            debugPrint("verification compare failed: $e");
          } finally {
            verificationCtx.dispose();
          }
        }

        // If best score above threshold, set current match name
        if (bestMatchName != null && bestScore >= MATCH_THRESHOLD) {
          setState(() {
            _currentMatchName = bestMatchName;
            _currentScore = bestScore;
          });
        } else {
          setState(() {
            _currentMatchName = null;
            _currentScore = bestScore;
          });
        }

        // Dispose probe template (if required - check SDK docs; many wrapper objects require explicit dispose)
        probeTemplate.dispose();
      } finally {
        data.dispose(); // free context resources
      }
    } catch (e, st) {
      debugPrint("Frame processing error: $e\n$st");
    } finally {
      _isProcessingFrame = false;
    }
  }

  // ---------- UI & helpers ----------

  Widget _buildCameraPreview() {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      children: [
        CameraPreview(_cameraController!),
        // overlay showing matched name — position above center for demo
        Positioned(
          top: 30,
          left: 0,
          right: 0,
          child: Column(
            children: [
              if (_currentMatchName != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    "${_currentMatchName!} (${(_currentScore * 100).toStringAsFixed(1)}%)",
                    style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    "No match",
                    style: TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _stopCamera() async {
    try {
      await _cameraController?.stopImageStream();
      await _cameraController?.dispose();
    } catch (e) {
      // ignore
    } finally {
      _cameraController = null;
    }
  }

  void _disposeFaceSdk() {
    try {
      // dispose loaded ContextTemplate objects
      for (final kv in _templatesIndex.entries) {
        final ct = kv.value["template"] as ContextTemplate?;
        try { ct?.dispose(); } catch (_) {}
      }
      _templatesIndex.clear();

      _faceDetector?.dispose();
      _faceFitter?.dispose();
      _templateExtractor?.dispose();
      _verificationModule?.dispose();

      _service.dispose();
    } catch (e) {
      debugPrint("Disposing Face SDK error: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Identify Face (1:N)"),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              // reload templates from storage (useful after registering new faces)
              await _loadSavedTemplates();
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Templates reloaded")));
            },
          )
        ],
      ),
      body: SafeArea(
        child: _buildCameraPreview(),
      ),
    );
  }
}
