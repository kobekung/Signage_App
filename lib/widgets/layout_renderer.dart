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
    final normalWidgets = layout.widgets.where((w) => w.id != fullscreenWidgetId).toList();
    final fullscreenWidget = layout.widgets.where((w) => w.id == fullscreenWidgetId).firstOrNull;

    return Container(
      color: Colors.black,
      child: Center(
        child: FittedBox(
          fit: BoxFit.cover,
          alignment: Alignment.center,
          child: Container(
            width: layout.width,
            height: layout.height,
            color: _parseColor(layout.backgroundColor),
            child: Stack(
              children: [
                ...normalWidgets.map((w) {
                  return Positioned(
                    left: w.x,
                    top: w.y,
                    width: w.width,
                    height: w.height,
                    child: _buildContentWithOverrideCheck(w),
                  );
                }),

                if (fullscreenWidget != null)
                  Positioned(
                    left: 0,
                    top: 0,
                    width: layout.width,
                    height: layout.height,
                    child: _buildContentWithOverrideCheck(fullscreenWidget),
                  ),
              ],
            ),
          ),
        ),
      ),
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