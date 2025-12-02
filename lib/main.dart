import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'pages/loading_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  try {
    await dotenv.load(fileName: ".env");
  } catch (_) {}
  
  // [เพิ่ม] ซ่อน Status Bar และ Navigation Bar (Full Screen)
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  
  // บังคับแนวนอน
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Signage Player',
      theme: ThemeData.dark(), // ใช้ Dark theme เพื่อให้พื้นหลังดำสนิท
      home: const LoadingPage(),
    );
  }
}