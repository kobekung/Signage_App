/// ความเร็วเสียงเริ่มต้น (ค่าเดิมที่ _initTts เคยตั้งไว้ตายตัว)
const double kDefaultTtsRate = 0.5;

class TtsLangConfig {
  final String code;        // TTS locale e.g. 'th-TH', 'ru-RU', 'pt-BR'
  final String label;       // display label e.g. '🇹🇭 ไทย'
  final String nameField;   // 'th' = ใช้ชื่อภาษาไทย, 'en' = ใช้ชื่อภาษาอังกฤษ
  final String tmplWelcome; // {route},{first},{last}
  final String tmplThankYou;// {route},{last}
  final String tmplNextStop;// {name}
  final bool enabled;       // เปิดใช้งานหรือไม่
  final double rate;        // ความเร็วเสียง 0.1–1.0 (แยกของใครของมัน)
  final String gender;      // 'auto' | 'female' | 'male'

  const TtsLangConfig({
    required this.code,
    required this.label,
    this.nameField = 'en',
    required this.tmplWelcome,
    required this.tmplThankYou,
    required this.tmplNextStop,
    this.enabled = true,
    this.rate = kDefaultTtsRate,
    this.gender = 'auto',
  });

  String buildWelcome({required String route, required String first, required String last}) =>
      tmplWelcome
          .replaceAll('{route}', route)
          .replaceAll('{first}', first)
          .replaceAll('{last}', last);

  String buildThankYou({required String route, required String last}) =>
      tmplThankYou
          .replaceAll('{route}', route)
          .replaceAll('{last}', last);

  String buildNextStop({required String name}) =>
      tmplNextStop.replaceAll('{name}', name);

  Map<String, dynamic> toJson() => {
        'code': code,
        'label': label,
        'nameField': nameField,
        'tmplWelcome': tmplWelcome,
        'tmplThankYou': tmplThankYou,
        'tmplNextStop': tmplNextStop,
        'enabled': enabled,
        'rate': rate,
        'gender': gender,
      };

  factory TtsLangConfig.fromJson(Map<String, dynamic> j) => TtsLangConfig(
        code: j['code'] as String,
        label: j['label'] as String,
        nameField: (j['nameField'] as String?) ?? 'en',
        tmplWelcome: j['tmplWelcome'] as String,
        tmplThankYou: j['tmplThankYou'] as String,
        tmplNextStop: j['tmplNextStop'] as String,
        enabled: (j['enabled'] as bool?) ?? true,
        // ค่าที่บันทึกไว้ก่อนมีฟีเจอร์นี้จะไม่มี 2 คีย์นี้ → ใช้ค่าเริ่มต้น
        rate: (j['rate'] as num?)?.toDouble() ?? kDefaultTtsRate,
        gender: (j['gender'] as String?) ?? 'auto',
      );

  TtsLangConfig copyWith({
    String? code,
    String? label,
    String? nameField,
    String? tmplWelcome,
    String? tmplThankYou,
    String? tmplNextStop,
    bool? enabled,
    double? rate,
    String? gender,
  }) =>
      TtsLangConfig(
        code: code ?? this.code,
        label: label ?? this.label,
        nameField: nameField ?? this.nameField,
        tmplWelcome: tmplWelcome ?? this.tmplWelcome,
        tmplThankYou: tmplThankYou ?? this.tmplThankYou,
        tmplNextStop: tmplNextStop ?? this.tmplNextStop,
        enabled: enabled ?? this.enabled,
        rate: rate ?? this.rate,
        gender: gender ?? this.gender,
      );
}

/// ค่าเริ่มต้น 4 ภาษา (ไทย + อังกฤษ เปิดใช้, จีน + รัสเซีย ปิดไว้)
List<TtsLangConfig> defaultTtsLanguages = [
  const TtsLangConfig(
    code: 'th-TH',
    label: '🇹🇭 ไทย',
    nameField: 'th',
    enabled: true,
    tmplWelcome: 'ยินดีต้อนรับเข้าสู่เส้นทาง{route} โดยจะเริ่มที่{first} จบที่{last}',
    tmplThankYou: 'ขอบคุณที่ใช้บริการ เส้นทาง{route} ถึงสถานีสุดท้าย{last}',
    tmplNextStop: 'สถานีถัดไป {name}',
  ),
  const TtsLangConfig(
    code: 'en-US',
    label: '🇬🇧 English',
    nameField: 'en',
    enabled: true,
    tmplWelcome: 'Welcome to route {route}. Starting from {first}, ending at {last}.',
    tmplThankYou: 'Thank you for using route {route}. Last stop: {last}.',
    tmplNextStop: 'Next stop, {name}.',
  ),
  const TtsLangConfig(
    code: 'zh-CN',
    label: '🇨🇳 中文',
    nameField: 'en',
    enabled: false,
    tmplWelcome: '欢迎乘坐{route}路线，从{first}出发，终点为{last}。',
    tmplThankYou: '感谢乘坐{route}路线，终点站{last}。',
    tmplNextStop: '下一站，{name}。',
  ),
  const TtsLangConfig(
    code: 'ru-RU',
    label: '🇷🇺 Русский',
    nameField: 'en',
    enabled: false,
    tmplWelcome: 'Добро пожаловать на маршрут {route}, от {first} до {last}.',
    tmplThankYou: 'Спасибо за поездку на маршруте {route}. Конечная — {last}.',
    tmplNextStop: 'Следующая остановка — {name}.',
  ),
];
