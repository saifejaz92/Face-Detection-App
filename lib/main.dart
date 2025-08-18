import 'package:face_detection_app/screens/home_page.dart';
import 'package:face_detection_app/screens/register_face.dart';
import 'package:face_sdk_3divi/face_sdk_3divi.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

late FacerecService gFaceService;
void main() async{
  WidgetsFlutterBinding.ensureInitialized();

  await _requestPermissions();
  gFaceService = await FaceSdkPlugin.createFacerecService();
  runApp(const MyApp());
}
Future<void> _requestPermissions() async {
  await [
    Permission.camera,
    Permission.storage,
  ].request();
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Flutter Demo',
      home: const HomePage(),
    );
  }
}