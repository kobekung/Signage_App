import 'package:flutter/material.dart';
import '../models/layout_model.dart';
import 'content_player.dart';

class LayoutRenderer extends StatelessWidget {
  final SignageLayout layout;
  
  // [NEW] รับข้อมูล Trigger แบบ In-Place
  final Map<String, dynamic> inPlaceTriggers; // Map<WidgetId, ItemData>
  final Function(String widgetId) onInPlaceFinished;

  // ข้อมูล Fullscreen ปกติ
  final String? fullscreenWidgetId;
  final Function(String id, bool isFull) onWidgetFullscreen;

  const LayoutRenderer({
    super.key, 
    required this.layout,
    required this.inPlaceTriggers,   // [NEW]
    required this.onInPlaceFinished, // [NEW]
    this.fullscreenWidgetId,
    required this.onWidgetFullscreen,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final scaleX = size.width / layout.width;
    final scaleY = size.height / layout.height;
    final scale = scaleX < scaleY ? scaleX : scaleY;

    // แยก Widget ปกติ กับ ตัวที่ขยายเต็มจอ (ที่ไม่ใช่ Trigger)
    final normalWidgets = layout.widgets.where((w) => w.id != fullscreenWidgetId).toList();
    final fullscreenWidget = layout.widgets.where((w) => w.id == fullscreenWidgetId).firstOrNull;

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
            children: [
              // 1. วาด Widget
              ...normalWidgets.map((w) {
                return Positioned(
                  left: w.x * scale,
                  top: w.y * scale,
                  width: w.width * scale,
                  height: w.height * scale,
                  child: _buildContentWithTriggerCheck(w),
                );
              }),

              // 2. วาด Fullscreen Widget (Normal Playlist)
              if (fullscreenWidget != null)
                Positioned(
                  left: 0,
                  top: 0,
                  width: layout.width * scale,
                  height: layout.height * scale,
                  child: _buildContentWithTriggerCheck(fullscreenWidget),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ฟังก์ชันเช็คว่า Widget นี้โดน Trigger ไหม
  Widget _buildContentWithTriggerCheck(SignageWidget w) {
    // เช็คว่า ID นี้มี Trigger ค้างอยู่ไหม
    final triggerItem = inPlaceTriggers[w.id];

    if (triggerItem != null) {
      // [CASE TRIGGER]: สร้าง Widget จำลองที่มี Item เดียว
      final triggerWidget = SignageWidget(
        id: "${w.id}-trigger", // ID ปลอม
        type: w.type,
        x: w.x, y: w.y, width: w.width, height: w.height,
        properties: {
          ...w.properties,
          'playlist': [triggerItem], // บังคับเล่น Item นี้
          'url': null
        }
      );

      return ContentPlayer(
        // Key สำคัญ! ต้องเปลี่ยนเพื่อให้ React สร้างใหม่ (Switch จาก Normal -> Trigger)
        key: ValueKey("trigger-${w.id}-${triggerItem['id']}"), 
        widget: triggerWidget,
        isTriggerMode: true,
        onFinished: () => onInPlaceFinished(w.id), // แจ้งจบ
      );
    } 
    
    // [CASE NORMAL]: เล่นตาม Playlist ปกติ
    else {
      return ContentPlayer(
        key: ValueKey("normal-${w.id}"), // Key ปกติ
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