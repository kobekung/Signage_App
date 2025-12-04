import 'package:flutter/material.dart';
import '../models/layout_model.dart';
import 'content_player.dart';

class LayoutRenderer extends StatelessWidget {
  final SignageLayout layout;
  
  // รับข้อมูล Trigger แบบ In-Place (แทรกในกรอบเดิม)
  final Map<String, dynamic> inPlaceTriggers; // Map<WidgetId, ItemData>
  final Function(String widgetId) onInPlaceFinished;

  // ข้อมูล Fullscreen จาก Playlist ปกติ
  final String? fullscreenWidgetId;
  final Function(String id, bool isFull) onWidgetFullscreen;

  const LayoutRenderer({
    super.key, 
    required this.layout,
    required this.inPlaceTriggers,
    required this.onInPlaceFinished,
    this.fullscreenWidgetId,
    required this.onWidgetFullscreen,
  });

  @override
  Widget build(BuildContext context) {
    // แยก Widget: ตัวปกติ vs ตัวที่ขอ Fullscreen (เพื่อให้ตัว Fullscreen วาดทับเพื่อน)
    final normalWidgets = layout.widgets.where((w) => w.id != fullscreenWidgetId).toList();
    final fullscreenWidget = layout.widgets.where((w) => w.id == fullscreenWidgetId).firstOrNull;

    return Container(
      color: Colors.black,
      child: Center(
        // [FIX] ใช้ FittedBox เพื่อขยาย Layout ให้เต็มจอทีวีอัตโนมัติ
        child: FittedBox(
          fit: BoxFit.cover, // cover = เต็มจอโดยตัดส่วนเกิน, contain = เห็นครบแต่มีขอบดำ
          alignment: Alignment.center,
          child: Container(
            // กำหนดขนาด Container ตามขนาด Layout จริง (เช่น 1920x1080)
            width: layout.width,
            height: layout.height,
            color: _parseColor(layout.backgroundColor),
            child: Stack(
              children: [
                // 1. วาด Widget ปกติ (ใช้ค่า x, y, w, h ตามจริง ไม่ต้องคูณ scale)
                ...normalWidgets.map((w) {
                  return Positioned(
                    left: w.x,
                    top: w.y,
                    width: w.width,
                    height: w.height,
                    child: _buildContentWithTriggerCheck(w),
                  );
                }),

                // 2. วาด Widget ที่ขอ Fullscreen (จาก Playlist ปกติ)
                if (fullscreenWidget != null)
                  Positioned(
                    left: 0,
                    top: 0,
                    width: layout.width, // บังคับเต็ม Layout
                    height: layout.height,
                    child: _buildContentWithTriggerCheck(fullscreenWidget),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ฟังก์ชันตรวจสอบว่า Widget นี้ต้องเล่นตัวแทรก (Trigger) หรือตัวปกติ
  Widget _buildContentWithTriggerCheck(SignageWidget w) {
    // เช็คว่า Widget ID นี้ มีคำสั่ง Trigger ค้างอยู่ไหม
    final triggerItem = inPlaceTriggers[w.id];

    if (triggerItem != null) {
      // [CASE TRIGGER]: สร้าง Widget จำลองที่มีแค่ Item เดียวเพื่อเล่นแทรก
      final triggerWidget = SignageWidget(
        id: "${w.id}-trigger", // สร้าง ID ปลอมเพื่อ force rebuild
        type: w.type,
        x: w.x, y: w.y, width: w.width, height: w.height,
        properties: {
          ...w.properties,
          'playlist': [triggerItem], // ใส่แค่ item ที่ trigger
          'url': null
        }
      );

      return ContentPlayer(
        // Key สำคัญ! เปลี่ยนเพื่อให้ React สร้าง Player ใหม่
        key: ValueKey("trigger-${w.id}-${triggerItem['id']}"), 
        widget: triggerWidget,
        isTriggerMode: true,
        onFinished: () => onInPlaceFinished(w.id), // เล่นจบแจ้งลบ trigger
      );
    } 
    
    // [CASE NORMAL]: เล่น Playlist ปกติ
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