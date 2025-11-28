import 'package:flutter/material.dart';
import '../models/layout_model.dart';
import '../widgets/layout_renderer.dart';
import 'setup_page.dart';

class PlayerPage extends StatelessWidget {
  final SignageLayout layout;
  const PlayerPage({super.key, required this.layout});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          LayoutRenderer(layout: layout),
          // ปุ่มลับ มุมขวาบน กด 3 ครั้งเพื่อกลับหน้า Setup
          Positioned(
            top: 0, right: 0,
            child: GestureDetector(
              onDoubleTap: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const SetupPage())),
              child: Container(width: 50, height: 50, color: Colors.transparent),
            ),
          )
        ],
      ),
    );
  }
}