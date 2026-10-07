/// ข้อมูลเสียงของ route จาก GET /bussing/route-audio (ชุดเดียวกับที่แท็บเล็ตคนขับใช้เล่น)
class RouteAudio {
  final int routeId;
  final String nameTh;
  final String nameEn;
  final String mp3Start;
  final String mp3Stop;
  final String mp3Version;
  final String ttsStart;
  final String ttsStop;
  final String modeStart; // 'mp3' | 'none' (พูดจาก template) | อื่น ๆ = text
  final String modeStop;
  final List<RouteAudioStation> stations; // ตามลำดับ route_array (id 0 = จุดคั่น)
  final List<String> bgSounds; // ชื่อไฟล์เสียง bg ตามลำดับ playlist

  const RouteAudio({
    required this.routeId,
    required this.nameTh,
    required this.nameEn,
    required this.mp3Start,
    required this.mp3Stop,
    required this.mp3Version,
    required this.ttsStart,
    required this.ttsStop,
    required this.modeStart,
    required this.modeStop,
    required this.stations,
    required this.bgSounds,
  });

  factory RouteAudio.fromJson(Map<String, dynamic> j) {
    final r = (j['route'] as Map?)?.cast<String, dynamic>() ?? const {};
    String s(dynamic v) => v?.toString() ?? '';
    return RouteAudio(
      routeId: int.tryParse(s(r['route_id'])) ?? 0,
      nameTh: s(r['route_name_th']),
      nameEn: s(r['route_name_en']).isNotEmpty ? s(r['route_name_en']) : s(r['route_name_th']),
      mp3Start: s(r['route_mp3_start']),
      mp3Stop: s(r['route_mp3_stop']),
      mp3Version: s(r['route_mp3_version']),
      ttsStart: s(r['route_tts_start']),
      ttsStop: s(r['route_tts_stop']),
      modeStart: s(r['audio_mode_start']).isNotEmpty ? s(r['audio_mode_start']) : 'mp3',
      modeStop: s(r['audio_mode_stop']).isNotEmpty ? s(r['audio_mode_stop']) : 'mp3',
      stations: ((j['locations'] as List?) ?? const [])
          .map((e) => RouteAudioStation.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
      bgSounds: ((j['bg_sounds'] as List?) ?? const [])
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList(),
    );
  }
}

class RouteAudioStation {
  final int id;
  final String nameTh;
  final String nameEn;
  final String mp3;
  final String mp3Version;
  final String ttsText;
  final String mode;

  const RouteAudioStation({
    required this.id,
    required this.nameTh,
    required this.nameEn,
    required this.mp3,
    required this.mp3Version,
    required this.ttsText,
    required this.mode,
  });

  factory RouteAudioStation.fromJson(Map<String, dynamic> j) {
    String s(dynamic v) => v?.toString() ?? '';
    return RouteAudioStation(
      id: int.tryParse(s(j['route_location_id'])) ?? 0,
      nameTh: s(j['route_location_name']),
      nameEn: s(j['route_location_name_en']),
      mp3: s(j['mp3']),
      mp3Version: s(j['mp3_version']),
      ttsText: s(j['tts_text']),
      mode: s(j['audio_mode']).isNotEmpty ? s(j['audio_mode']) : 'mp3',
    );
  }
}
