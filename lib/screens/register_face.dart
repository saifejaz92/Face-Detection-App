// register_face_screen.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:face_sdk_3divi/face_sdk_3divi.dart';

import '../main.dart';

// Use the global service initialized in main.dart

class RegisterFaceScreen extends StatefulWidget {
  const RegisterFaceScreen({super.key});

  @override
  State<RegisterFaceScreen> createState() => _RegisterFaceScreenState();
}

class _RegisterFaceScreenState extends State<RegisterFaceScreen> {
  CameraController? _cameraController;
  List<CameraDescription>? _cameras;
  bool _initializing = true;
  bool _isRegistering = false;

  // face sdk components (async processing blocks are recommended)
  ProcessingBlock? _faceDetector;
  AsyncProcessingBlock? _faceFitter;
  AsyncProcessingBlock? _templateExtractor;

  // local index file name that stores registered users
  late File _indexFile;
  Map<String, dynamic> _index = {};

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    try {
      _cameras = await availableCameras();
      CameraDescription cameraToUse =
      _cameras!.firstWhere((c) => c.lensDirection == CameraLensDirection.front,
          orElse: () => _cameras!.first);

      _cameraController = CameraController(
        cameraToUse,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await _cameraController!.initialize();

      final appDoc = await getApplicationDocumentsDirectory();
      _indexFile = File('${appDoc.path}/templates_index.json');
      // helper to copy model
      Future<String> _copyAssetModel(String assetPath, String filename) async {
        final byteData = await rootBundle.load(assetPath);
        final file = File(p.join(appDoc.path, filename));
        await file.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
        return file.path;
      }


      // create blocks
      _faceDetector =  gFaceService.createProcessingBlock(
          {"unit_type": "FACE_DETECTOR", "modification": "blf_front"});

      _faceFitter = await gFaceService.createAsyncProcessingBlock({
        "unit_type": "FACE_FITTER",
        "modification": "tddfa_faster",
      });

      _templateExtractor = await gFaceService.createAsyncProcessingBlock({
        "unit_type": "FACE_TEMPLATE_EXTRACTOR",
        "modification": "30",
      });

      setState(() => _initializing = false);
    } catch (e, st) {
      debugPrint("Setup failed: $e\n$st");
      _showMessage("Face SDK init failed: ${e.toString()}");
    }
  }


  @override
  void dispose() {
    _cameraController?.dispose();
    _faceDetector?.dispose();
    _faceFitter?.dispose();
    _templateExtractor?.dispose();
    super.dispose();
  }

  /// Called when user taps Capture button.
  /// Flow:
  ///  1. take picture -> bytes
  ///  2. create Context from encoded image bytes
  ///  3. faceDetector.process, faceFitter.process, templateExtractor.process
  ///  4. read template bytes and save to a file
  ///  5. prompt user for name and save mapping
  Future<void> _captureAndRegister() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    if (_isRegistering) return;

    setState(() => _isRegistering = true);

    try {
      XFile file = await _cameraController!.takePicture();
      Uint8List imgBytes = await File(file.path).readAsBytes();

      // create context from encoded image bytes (docs show this function)
      Context data = gFaceService.createContextFromEncodedImage(imgBytes);

      // 1) detect
       _faceDetector!.process(data);

      // check results
      if (data["objects"].len() == 0) {
        // no face found
        data.dispose();
        _showMessage("No face detected. Try again.");
        return;
      } else if (data["objects"].len() > 1) {
        // multiple faces found
        data.dispose();
        _showMessage("More than one face detected. Make sure only one person is in frame.");
        return;
      }
//work
      // 2) fit (keypoints)
      await _faceFitter!.process(data);

      // 3) extract template
      await _templateExtractor!.process(data);

      // fetch template from context
      // per docs: after templateExtractor.process(data) the template is at data["objects"][0]["face_template"]["template"]
      // get_value() returns ContextTemplate (binary). In plugin it maps to a Uint8List when using .get_value()
      dynamic templObj = data["objects"][0]["face_template"]["template"].get_value();

      // templObj should be a Uint8List blob per plugin docs
      // print(templObj.);

      Uint8List templateBytes;
      if (templObj is Uint8List || 1==1) {
        templateBytes = templObj.save();
      } else if (templObj is List<int>) {
        templateBytes = Uint8List.fromList(List<int>.from(templObj));
      } else {
        data.dispose();
        _showMessage("Failed to extract template (unexpected template type).");
        return;
      }

      // Save template bytes to file
      final appDoc = await getApplicationDocumentsDirectory();
      final templatesDir = Directory(p.join(appDoc.path, 'face_templates'));
      if (!templatesDir.existsSync()) templatesDir.createSync(recursive: true);

      final id = DateTime.now().millisecondsSinceEpoch.toString();
      final templatePath = p.join(templatesDir.path, '$id.bin');
      final templateFile = File(templatePath);
      await templateFile.writeAsBytes(templateBytes);


      data.dispose();

      // show dialog to get name and save mapping
      final name = await _askForName();
      if (name == null || name.trim().isEmpty) {
        // user cancelled — you might want to delete saved template file
        await templateFile.delete().catchError((_) {});
        _showMessage("Registration cancelled.");
        return;
      }

      // add to index
      _index[id] = {
        "name": name.trim(),
        "file": templatePath,
        "created_at": DateTime.now().toIso8601String()
      };
      await _indexFile.writeAsString(json.encode(_index));

      _showMessage("Face registered for $name");

    } catch (e, st) {
      debugPrint('Error during register: $e\n$st');
      _showMessage("Error during registration: ${e.toString()}");
    } finally {
      setState(() => _isRegistering = false);
    }
  }

  Future<String?> _askForName() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) {
        return AlertDialog(
          title: const Text('Enter name'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Full name'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(null), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.of(context).pop(controller.text), child: const Text('Save')),
          ],
        );
      },
    );
  }

  void _showMessage(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    if (_initializing) {
      return Scaffold(
        appBar: AppBar(title: const Text('Register face')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Register face')),
      body: Column(
        children: [
          Expanded(
            child: _cameraController != null && _cameraController!.value.isInitialized
                ? CameraPreview(_cameraController!)
                : const Center(child: Text('Camera not available')),
          ),
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    icon: _isRegistering ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.camera),
                    label: Text(_isRegistering ? 'Registering...' : 'Capture & Register'),
                    onPressed: _isRegistering ? null : _captureAndRegister,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
