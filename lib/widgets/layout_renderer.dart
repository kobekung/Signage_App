import 'package:flutter/material.dart';
import '../models/layout_model.dart';
import 'content_player.dart';

class LayoutRenderer extends StatelessWidget {
  final SignageLayout layout;
  
  // [UPDATED] รับเป็น Map<WidgetId, List<Items>>
  final Map<String, List<dynamic>> locationOverrides; 

  final String? fullscreenWidgetId;
  final Function(String id, bool isFull) onWidgetFullscreen;

  const LayoutRenderer({
    super.key, 
    required this.layout,
    required this.locationOverrides,
    this.fullscreenWidgetId,
    required this.onWidgetFullscreen,
  });

  @override
  Widget build(BuildContext context) {
    final normalWidgets =
        layout.widgets.where((w) => w.id != fullscreenWidgetId).toList();
    final fullscreenWidget =
        layout.widgets.where((w) => w.id == fullscreenWidgetId).firstOrNull;

    // IMPORTANT:
    // Avoid scaling the whole tree with FittedBox/Transform because PlatformView/Texture
    // (Video/WebView) can disappear or fail to render on Android when transformed.
    // Instead, scale the layout numerically (positions/sizes), keeping widgets untransformed.
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight;

        // BoxFit.cover behavior
        final scaleW = maxW / layout.width;
        final scaleH = maxH / layout.height;
        final scale = scaleW > scaleH ? scaleW : scaleH;

        final scaledW = layout.width * scale;
        final scaledH = layout.height * scale;

        final dx = (maxW - scaledW) / 2;
        final dy = (maxH - scaledH) / 2;

        return Container(
          color: Colors.black,
          child: Center(
            child: SizedBox(
              width: maxW,
              height: maxH,
              child: Stack(
                children: [
                  // Background
                  Positioned(
                    left: dx,
                    top: dy,
                    width: scaledW,
                    height: scaledH,
                    child: Container(color: _parseColor(layout.backgroundColor)),
                  ),

                  // Normal widgets
                  ...normalWidgets.map((w) {
                    return Positioned(
                      left: dx + (w.x * scale),
                      top: dy + (w.y * scale),
                      width: w.width * scale,
                      height: w.height * scale,
                      child: _buildContentWithOverrideCheck(w),
                    );
                  }),

                  // Fullscreen widget overlay
                  if (fullscreenWidget != null)
                    Positioned(
                      left: dx,
                      top: dy,
                      width: scaledW,
                      height: scaledH,
                      child: _buildContentWithOverrideCheck(fullscreenWidget),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildContentWithOverrideCheck(SignageWidget w) {
    // [UPDATED] รับมาเป็น List ของ Items
    final overrideItems = locationOverrides[w.id];

    if (overrideItems != null && overrideItems.isNotEmpty) {
      // ดึง Location ID จากตัวแรกเพื่อใช้ทำ Key (สมมติว่า Location เดียวกัน)
      final locId = overrideItems.first['locationId'];

      final overrideWidget = SignageWidget(
        id: "${w.id}-loc-$locId", 
        type: w.type,
        x: w.x, y: w.y, width: w.width, height: w.height,
        properties: {
          ...w.properties,
          'playlist': overrideItems, // [FIX] ใส่ List ทั้งก้อนลงไปเลย
          'url': null
        }
      );

      return ContentPlayer(
        // เปลี่ยน Key ตาม Location เพื่อ Rebuild เมื่อเปลี่ยนป้าย
        key: ValueKey("loc-player-${w.id}-$locId"), 
        widget: overrideWidget,
        isTriggerMode: false, // Loop
      );
    } 
    
    else {
      return ContentPlayer(
        key: ValueKey("normal-${w.id}"), 
        widget: w,
        onFullscreenChange: (isFull) => onWidgetFullscreen(w.id, isFull),
      );
    }
  }

  Color _parseColor(String hex) {
    try {
      hex = hex.replaceAll('#', '');
      if (hex.length == 6) hex = 'FF$hex';
      return Color(int.parse(hex, radix: 16));
    } catch (_) { return Colors.black; }
  }
}