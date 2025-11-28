import 'package:flutter/material.dart';
import '../models/layout_model.dart';
import 'content_player.dart';

class LayoutRenderer extends StatelessWidget {
  final SignageLayout layout;

  const LayoutRenderer({super.key, required this.layout});

  @override
  Widget build(BuildContext context) {
    // คำนวณ Scale
    final size = MediaQuery.of(context).size;
    final scaleX = size.width / layout.width;
    final scaleY = size.height / layout.height;
    final scale = scaleX < scaleY ? scaleX : scaleY; // Maintain Aspect Ratio

    return Container(
      width: size.width,
      height: size.height,
      color: Colors.black,
      child: Center(
        child: Container(
          width: layout.width * scale,
          height: layout.height * scale,
          color: _parseColor(layout.backgroundColor),
          child: Stack(
            children: layout.widgets.map((w) {
              return Positioned(
                left: w.x * scale,
                top: w.y * scale,
                width: w.width * scale,
                height: w.height * scale,
                child: ContentPlayer(widget: w),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Color _parseColor(String hex) {
    try {
      hex = hex.replaceAll('#', '');
      if (hex.length == 6) hex = 'FF$hex';
      return Color(int.parse(hex, radix: 16));
    } catch (_) { return Colors.black; }
  }
}