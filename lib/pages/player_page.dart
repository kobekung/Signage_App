import 'package:flutter/material.dart';
import '../models/layout_model.dart';
import '../widgets/layout_renderer.dart';
import 'setup_page.dart';

class PlayerPage extends StatefulWidget {
  final SignageLayout layout;
  const PlayerPage({super.key, required this.layout});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  bool _showControls = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        // แตะหน้าจอเพื่อโชว์ปุ่มออก
        onTap: () {
          setState(() {
            _showControls = !_showControls;
          });
          // ซ่อนปุ่มอัตโนมัติใน 3 วินาที
          if (_showControls) {
            Future.delayed(const Duration(seconds: 3), () {
              if (mounted) setState(() => _showControls = false);
            });
          }
        },
        child: Stack(
          children: [
            // Layer 1: ตัวแสดงผลหลัก
            LayoutRenderer(layout: widget.layout),

            // Layer 2: ปุ่มย้อนกลับ (แสดงเมื่อ _showControls = true)
            if (_showControls)
              Positioned(
                top: 20,
                right: 20,
                child: SafeArea(
                  child: FloatingActionButton(
                    backgroundColor: Colors.red.withOpacity(0.8),
                    child: const Icon(Icons.close, color: Colors.white),
                    onPressed: () {
                      Navigator.pushReplacement(
                        context, 
                        MaterialPageRoute(builder: (_) => const SetupPage())
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}