// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:overlay_support/overlay_support.dart'; // [Added] ต้องเพิ่มบรรทัดนี้
import 'package:media_kit/media_kit.dart';
import 'pages/loading_page.dart';
import 'utils/rotation_manager.dart';
import 'services/tts_service.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  
  try {
    await dotenv.load(fileName: ".env");
  } catch (e) {
    print("Error loading .env: $e");
  }
  
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // โหลดค่าการหมุนจอที่ผู้ใช้ตั้งไว้ (แนวตั้ง/แนวนอน) จาก local storage
  await RotationManager.load();
  await TtsService.loadSetting();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // [Fixed] ต้องหุ้มด้วย OverlaySupport.global() เพื่อให้แสดง Toast/Notification ได้
    return OverlaySupport.global(
      child: MaterialApp(
        navigatorKey: navigatorKey,
        debugShowCheckedModeBanner: false,
        title: 'Signage Player',
        theme: ThemeData.dark(),
        builder: (context, child) {
          // หมุนทั้งแอปตามค่าที่ตั้งไว้ (รองรับจอที่ไม่รองรับ portrait orientation)
          return ValueListenableBuilder<int>(
            valueListenable: RotationManager.quarterTurns,
            builder: (context, turns, _) {
              if (turns == 0) return child ?? const SizedBox.shrink();
              return RotatedBox(
                quarterTurns: turns,
                // ขนาดจอ/ขอบ/คีย์บอร์ด ต้องหมุนตาม ไม่งั้น dialog คำนวณพื้นที่ผิดด้าน
                child: MediaQuery(
                  data: _rotateMediaQuery(MediaQuery.of(context), turns),
                  child: child ?? const SizedBox.shrink(),
                ),
              );
            },
          );
        },
        home: const LoadingPage(),
      ),
    );
  }
}
/// แปลง MediaQuery ของจอจริงให้เป็นมุมมองของเนื้อหาที่ถูกหมุนตามเข็มนาฬิกา [turns] ครั้ง
MediaQueryData _rotateMediaQuery(MediaQueryData data, int turns) {
  // หมุน 90° ตามเข็ม: ขอบบนของเนื้อหาไปอยู่ขวาจอ, ซ้าย→บน, ล่าง→ซ้าย, ขวา→ล่าง
  EdgeInsets rot(EdgeInsets e) {
    for (var i = 0; i < turns; i++) {
      e = EdgeInsets.fromLTRB(e.top, e.right, e.bottom, e.left);
    }
    return e;
  }

  return data.copyWith(
    size: turns.isOdd ? data.size.flipped : data.size,
    padding: rot(data.padding),
    viewPadding: rot(data.viewPadding),
    viewInsets: rot(data.viewInsets),
    systemGestureInsets: rot(data.systemGestureInsets),
  );
}
