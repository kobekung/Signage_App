import 'dart:convert';

/// รายการ playlist แบบ 'once': ไม่อยู่ใน loop ปกติ เล่นครั้งเดียวเมื่อรถถึง locationId
bool isOnceItem(dynamic item) => item is Map && item['playMode'] == 'once';

/// widget เว็บใน layout แบบ 'stop' (จอป้ายรถเมล์): ต่อท้าย URL ด้วย day=1 ถ้าวันนี้รถผ่าน, day=0 ถ้าไม่ผ่าน
/// (resolveBusVars ใส่ signageMode / passDays ของ layout ให้ widget)
/// passDays ใช้เลขวันแบบ JS getDay() (0 = อาทิตย์ ... 6 = เสาร์) ตามที่ studio บันทึก
/// layout แบบ 'bus' (ค่าเริ่มต้น) ใช้ URL เดิม
String resolveSignageUrl(String url, Map item, [DateTime? now]) {
  if (item['signageMode'] != 'stop') return url;

  final passDays = item['passDays'] is List
      ? (item['passDays'] as List).map((d) => int.tryParse(d.toString())).whereType<int>().toSet()
      : {0, 1, 2, 3, 4, 5, 6};
  final today = (now ?? DateTime.now()).weekday % 7; // Dart: จันทร์=1..อาทิตย์=7 → อาทิตย์=0
  final value = passDays.contains(today) ? '1' : '0';

  final dayParam = RegExp(r'([?&]day=)[^&#]*');
  if (dayParam.hasMatch(url)) {
    return url.replaceFirstMapped(dayParam, (m) => '${m[1]}$value');
  }
  final hashIndex = url.indexOf('#');
  final base = hashIndex >= 0 ? url.substring(0, hashIndex) : url;
  final hash = hashIndex >= 0 ? url.substring(hashIndex) : '';
  return '$base${base.contains('?') ? '&' : '?'}day=$value$hash';
}

/// 'bus' = จอบนรถ (ค่าเริ่มต้น), 'stop' = จอป้ายรถเมล์ผูกกับ location แทนรถ (ทั้งของจอและของ layout)
String parseSignageType(dynamic value) => value?.toString() == 'stop' ? 'stop' : 'bus';
int? parseLocationId(dynamic value) => int.tryParse(value?.toString() ?? '');

/// pass_days ของ layout: "1,2,3,4,5" → [1,2,3,4,5], 'none' → [], null/ว่าง → null (ทุกวัน)
List<int>? parsePassDays(dynamic value) {
  if (value == null) return null;
  if (value is List) return value.map((d) => int.tryParse(d.toString())).whereType<int>().toList();
  final s = value.toString().trim();
  if (s.isEmpty) return null;
  if (s == 'none') return [];
  return s.split(',').map((d) => int.tryParse(d.trim())).whereType<int>().where((d) => d >= 0 && d <= 6).toList();
}

/// แทน {busno} / {com_id} / {location_id} ใน URL ของทุก widget ด้วยจอนี้
/// (studio ให้ 1 layout ใช้กับรถหลายคันได้ เช่น ...tv02.html?busno={busno}&com_id={com_id})
/// และบอก widget เว็บว่า layout เป็นแบบป้ายรถเมล์หรือไม่ (ใช้ต่อ day=1/0)
SignageLayout resolveBusVars(SignageLayout layout, int busId, int companyId, [int? locationId]) {
  String resolve(String s) => s
      .replaceAll('{busno}', busId.toString())
      .replaceAll('{com_id}', companyId.toString())
      .replaceAll('{location_id}', locationId?.toString() ?? '');

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
    signageType: layout.signageType,
    passDays: layout.passDays,
    widgets: layout.widgets
        .map((w) => SignageWidget(
              id: w.id,
              type: w.type,
              x: w.x,
              y: w.y,
              width: w.width,
              height: w.height,
              properties: {
                ...Map<String, dynamic>.from(resolveValue(w.properties) as Map),
                'signageMode': layout.signageType,
                if (layout.passDays != null) 'passDays': layout.passDays,
              },
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
  final String signageType; // 'bus' | 'stop'
  final List<int>? passDays; // layout ป้ายรถเมล์: วันที่รถผ่าน (null = ทุกวัน)
  final List<SignageWidget> widgets;

  SignageLayout({
    required this.id,
    required this.name,
    required this.width,
    required this.version,
    required this.height,
    required this.backgroundColor,
    this.signageType = 'bus',
    this.passDays,
    required this.widgets,
  });

  factory SignageLayout.fromJson(Map<String, dynamic> json) {
    return SignageLayout(
      id: json['id'].toString(),
      name: json['name'] ?? 'Untitled',
      width: (json['width'] ?? 1920).toDouble(),
      height: (json['height'] ?? 1080).toDouble(),
      backgroundColor: json['background_color'] ?? '#000000',
      signageType: parseSignageType(json['signage_type']),
      passDays: parsePassDays(json['pass_days']),
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
      'signage_type': signageType,
      'pass_days': passDays == null ? null : (passDays!.isEmpty ? 'none' : passDays!.join(',')),
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