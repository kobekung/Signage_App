import 'dart:convert';

/// รายการ playlist แบบ 'once': ไม่อยู่ใน loop ปกติ เล่นครั้งเดียวเมื่อรถถึง locationId
bool isOnceItem(dynamic item) => item is Map && item['playMode'] == 'once';

/// แทน {busno} / {com_id} ใน URL ของทุก widget ด้วยรถคันนี้
/// (studio ให้ 1 layout ใช้กับรถหลายคันได้ เช่น ...tv02.html?busno={busno}&com_id={com_id})
SignageLayout resolveBusVars(SignageLayout layout, int busId, int companyId) {
  String resolve(String s) => s
      .replaceAll('{busno}', busId.toString())
      .replaceAll('{com_id}', companyId.toString());

  dynamic resolveValue(dynamic value) {
    if (value is String) return resolve(value);
    if (value is List) return value.map(resolveValue).toList();
    if (value is Map) return value.map((k, v) => MapEntry(k, resolveValue(v)));
    return value;
  }

  return SignageLayout(
    id: layout.id,
    name: layout.name,
    width: layout.width,
    version: layout.version,
    height: layout.height,
    backgroundColor: layout.backgroundColor,
    widgets: layout.widgets
        .map((w) => SignageWidget(
              id: w.id,
              type: w.type,
              x: w.x,
              y: w.y,
              width: w.width,
              height: w.height,
              properties: Map<String, dynamic>.from(resolveValue(w.properties) as Map),
            ))
        .toList(),
  );
}

class SignageLayout {
  final String id;
  final String name;
  final double width;
  final int version;
  final double height;
  final String backgroundColor;
  final List<SignageWidget> widgets;

  SignageLayout({
    required this.id,
    required this.name,
    required this.width,
    required this.version,
    required this.height,
    required this.backgroundColor,
    required this.widgets,
  });

  factory SignageLayout.fromJson(Map<String, dynamic> json) {
    return SignageLayout(
      id: json['id'].toString(),
      name: json['name'] ?? 'Untitled',
      width: (json['width'] ?? 1920).toDouble(),
      height: (json['height'] ?? 1080).toDouble(),
      backgroundColor: json['background_color'] ?? '#000000',
      widgets: (json['widgets'] as List?)
              ?.map((e) => SignageWidget.fromJson(e))
              .toList() ?? [],
      version: json['version'] ?? 1,
    );
  }

  // [NEW] เพิ่ม toJson เพื่อบันทึกข้อมูลลงเครื่อง
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'width': width,
      'height': height,
      'background_color': backgroundColor,
      'version': version,
      'widgets': widgets.map((e) => e.toJson()).toList(),
    };
  }
}

class SignageWidget {
  final String id;
  final String type;
  final double x;
  final double y;
  final double width;
  final double height;
  final Map<String, dynamic> properties;

  SignageWidget({
    required this.id,
    required this.type,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.properties,
  });

  factory SignageWidget.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic> props = {};
    if (json['properties'] is String) {
      try {
        props = jsonDecode(json['properties']);
      } catch (_) {}
    } else if (json['properties'] is Map) {
      props = Map<String, dynamic>.from(json['properties']);
    }

    return SignageWidget(
      id: json['id'].toString(),
      type: json['type'] ?? 'unknown',
      x: (json['x'] ?? 0).toDouble(),
      y: (json['y'] ?? 0).toDouble(),
      width: (json['width'] ?? 100).toDouble(),
      height: (json['height'] ?? 100).toDouble(),
      properties: props,
    );
  }

  // [NEW] เพิ่ม toJson
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'properties': properties,
    };
  }
}