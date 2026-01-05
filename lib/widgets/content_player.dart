// lib/widgets/content_player.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../models/layout_model.dart';
import '../services/preload_service.dart';

class ContentPlayer extends StatefulWidget {
  final SignageWidget widget;
  final VoidCallback? onFinished; 
  final bool isTriggerMode;       
  final Function(bool isFullscreen)? onFullscreenChange; 

  const ContentPlayer({
    super.key, 
    required this.widget,
    this.onFinished,
    this.isTriggerMode = false,
    this.onFullscreenChange,
  });

  @override
  State<ContentPlayer> createState() => _ContentPlayerState();
}

class _ContentPlayerState extends State<ContentPlayer> {
  int _currentIndex = 0;
  List<dynamic> _playlist = [];
  Widget? _currentContent;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _initPlaylist();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _initPlaylist() {
    final props = widget.widget.properties;
    
    if (props['playlist'] != null && (props['playlist'] as List).isNotEmpty) {
      _playlist = List.from(props['playlist']);
    } else if (props['url'] != null || props['text'] != null) {
      _playlist = [{
        'url': props['url'] ?? '',
        'text': props['text'] ?? props['content'],
        'type': widget.widget.type,
        'duration': 10,
        ...props
      }];
    }

    if (_playlist.isNotEmpty) {
      _playNext();
    }
  }

  void _playNext() async {
    if (!mounted) return;
    _timer?.cancel();

    // Loop logic
    if (_currentIndex >= _playlist.length) {
      if (widget.isTriggerMode && widget.onFinished != null) {
        widget.onFinished!(); 
        return; 
      } else {
        _currentIndex = 0; 
      }
    }

    final item = _playlist[_currentIndex];
    
    // Fullscreen callback
    final isFull = item['fullscreen'] == true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.onFullscreenChange != null && mounted) {
         widget.onFullscreenChange!(isFull);
      }
    });

    final type = item['type'] ?? widget.widget.type;
    int duration = 10;
    if (item['duration'] != null) {
      duration = int.tryParse(item['duration'].toString()) ?? 10;
    }

    Widget content;

    // --- VIDEO ---
    if (type == 'video') {
      final url = item['url'];
      File? cachedFile = await PreloadService.getCachedFile(url);
      
      bool shouldLoop = !widget.isTriggerMode && _playlist.length == 1;

      content = _MediaKitVideoItem(
        key: ValueKey("$url-$_currentIndex"), // Unique key forces rebuild
        file: cachedFile, 
        url: url,
        isLooping: shouldLoop, 
        onFinished: () {
           if (mounted) _nextItem();
        }
      );
    } 
    // --- IMAGE ---
    else if (type == 'image') {
      final url = item['url'];
      File? cachedFile = await PreloadService.getCachedFile(url);
      
      content = cachedFile != null 
          ? Image.file(cachedFile, fit: BoxFit.cover)
          : Image.network(url, fit: BoxFit.cover);
      
      _timer = Timer(Duration(seconds: duration), () {
        if (mounted) _nextItem();
      });
    }
    // --- WEBVIEW ---
    else if (type == 'webview') {
      final url = item['url'] ?? 'https://google.com';
      content = _WebviewItem(url: url);
      
      if (widget.isTriggerMode) {
         _timer = Timer(const Duration(seconds: 15), () => widget.onFinished?.call());
      } else if (_playlist.length > 1) {
         _timer = Timer(const Duration(seconds: 15), () => _nextItem());
      }
    }
    // --- TICKER ---
    else if (type == 'ticker') {
      content = _TickerItem(
        text: item['text'] ?? '',
        color: item['textColor'] ?? item['color'] ?? '#ffffff',
        fontSize: item['fontSize'] ?? 24,
        speed: item['speed'] ?? 50,
      );
       if (widget.isTriggerMode) {
         _timer = Timer(const Duration(seconds: 15), () => widget.onFinished?.call());
       } else if (_playlist.length > 1) {
         _timer = Timer(const Duration(seconds: 15), () => _nextItem());
       }
    }
    // --- TEXT ---
    else {
      content = Center(
        child: Text(
          item['text'] ?? item['content'] ?? '',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: double.tryParse((item['fontSize'] ?? 24).toString()) ?? 24,
            color: _parseColor(item['color'] ?? '#ffffff'),
          ),
        ),
      );
      
      if (widget.isTriggerMode) {
         _timer = Timer(Duration(seconds: duration), () => widget.onFinished?.call());
      } else if (_playlist.length > 1) {
         _timer = Timer(Duration(seconds: duration), () => _nextItem());
      }
    }

    if (mounted) {
      setState(() {
        _currentContent = content;
      });
    }
  }

  void _nextItem() {
      _currentIndex++;
      _playNext();
  }

  Color _parseColor(String? hex) {
    if (hex == null) return Colors.white;
    try {
      hex = hex.replaceAll('#', '');
      if (hex.length == 6) hex = 'FF$hex';
      return Color(int.parse(hex, radix: 16));
    } catch (_) { return Colors.white; }
  }

  @override
  Widget build(BuildContext context) {
    // [PERFORMANCE FIX] ลบ AnimatedSwitcher ออก
    // การทำ Fade Animation บน Video กิน CPU มาก ทำให้กระตุก
    // เปลี่ยนเป็น Container ธรรมดาเพื่อให้เปลี่ยนภาพทันที
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: Colors.black, 
      child: _currentContent ?? const SizedBox(),
    );
  }
}

// ==========================================
// 📽️ MediaKit Video Player Widget (Native Tuned)
// ==========================================
class _MediaKitVideoItem extends StatefulWidget {
  final File? file;
  final String url;
  final bool isLooping;
  final VoidCallback onFinished;

  const _MediaKitVideoItem({
    super.key, 
    this.file, 
    required this.url, 
    required this.isLooping, 
    required this.onFinished
  });

  @override
  State<_MediaKitVideoItem> createState() => _MediaKitVideoItemState();
}

class _MediaKitVideoItemState extends State<_MediaKitVideoItem> with WidgetsBindingObserver {
  late final Player player;
  late final VideoController controller;
  bool _isVideoReady = false; 

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    // 1. Player Config: Buffer เหมาะสมกับ HD
    player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 24 * 1024 * 1024, // 24MB (ค่ากลางๆ)
        logLevel: MPVLogLevel.warn,
      ),
    );

    // 2. Controller Config: เปิด HW Acceleration
    controller = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
        androidAttachSurfaceAfterVideoParameters: true,
      ),
    );

    _initPlayer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    player.dispose(); 
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // บังคับเล่นต่อถ้ากลับเข้ามา
      player.play();
    }
  }

  Future<void> _initPlayer() async {
    try {
      // [PERFORMANCE HACK] เจาะจงเรียกใช้คำสั่งระดับ Native
      // ต้อง cast เป็น dynamic เพราะเวอร์ชัน 1.1.10 ไม่มี method setProperty โดยตรง
      final native = player.platform as dynamic; 

      if (native != null) {
        try {
          // สั่งใช้ MediaCodec (ชิปวิดีโอของ Android)
          await native.setProperty('hwdec', 'mediacodec');
          await native.setProperty('hwdec-codecs', 'all');
          
          // ลดคุณภาพการประมวลผลที่ไม่จำเป็น
          await native.setProperty('profile', 'fast');
          await native.setProperty('vd-lavc-threads', '0'); 
          
          // สำคัญ! ช่วยเรื่องเสียงกับภาพไม่ตรงกันในกล่องสเปคต่ำ
          await native.setProperty('video-sync', 'audio'); 
        } catch (e) {
          print("Native property error (safe to ignore): $e");
        }
      }

      final Media media = widget.file != null 
          ? Media(widget.file!.path) 
          : Media(widget.url);

      await player.open(media, play: true);
      
      await player.setVolume(100.0);
      await player.setAudioTrack(AudioTrack.auto()); 
      await player.setPlaylistMode(widget.isLooping ? PlaylistMode.single : PlaylistMode.none);

      // รอให้ภาพมาจริงๆ ก่อนค่อยโชว์ (แก้จอดำ)
      player.stream.videoParams.listen((params) {
        if (params.w != null && params.h != null && !_isVideoReady) {
          if (mounted) setState(() => _isVideoReady = true);
        }
      });

      // Safety timeout 
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted && !_isVideoReady) {
           setState(() => _isVideoReady = true);
        }
      });

      player.stream.completed.listen((isCompleted) {
        if (isCompleted && !widget.isLooping) {
          widget.onFinished();
        }
      });

      player.stream.error.listen((error) {
        print("Media Error: $error");
        widget.onFinished(); 
      });

    } catch (e) {
      print("Init Error: $e");
      widget.onFinished();
    }
  }

  @override
  Widget build(BuildContext context) {
    // ใช้ Container สีดำธรรมดา ลดภาระการ render ของ AnimatedOpacity
    if (!_isVideoReady) {
      return const SizedBox(); // ไม่แสดงอะไรเลยช่วงโหลด
    }

    return Video(
      controller: controller,
      fit: BoxFit.cover,
      controls: NoVideoControls,
      fill: Colors.black, 
    );
  }
}

// --- Sub Widgets ---

class _WebviewItem extends StatefulWidget {
  final String url;
  const _WebviewItem({required this.url});
  @override
  State<_WebviewItem> createState() => _WebviewItemState();
}
class _WebviewItemState extends State<_WebviewItem> {
  late final WebViewController _controller;
  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..loadRequest(Uri.parse(widget.url));
  }
  @override
  Widget build(BuildContext context) { return WebViewWidget(controller: _controller); }
}

class _TickerItem extends StatefulWidget {
  final String text;
  final String color;
  final dynamic fontSize;
  final dynamic speed;
  const _TickerItem({required this.text, required this.color, this.fontSize, this.speed});
  @override
  State<_TickerItem> createState() => _TickerItemState();
}
class _TickerItemState extends State<_TickerItem> with SingleTickerProviderStateMixin {
  late ScrollController _scrollController;
  late AnimationController _animationController;
  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _animationController = AnimationController(vsync: this, duration: const Duration(seconds: 10));
    WidgetsBinding.instance.addPostFrameCallback((_) => _startScrolling());
  }
  void _startScrolling() {
    if (!_scrollController.hasClients) return;
    double maxScroll = _scrollController.position.maxScrollExtent;
    double screenWidth = MediaQuery.of(context).size.width;
    double speedVal = double.tryParse(widget.speed.toString()) ?? 50;
    int durationSec = ((maxScroll + screenWidth) / speedVal).round();
    if (durationSec < 2) durationSec = 2;
    _animationController.duration = Duration(seconds: durationSec);
    _animationController.addListener(() {
      if (_scrollController.hasClients) {
        double offset = _animationController.value * maxScroll;
        _scrollController.jumpTo(offset);
      }
    });
    _animationController.repeat(); 
  }
  @override
  void dispose() { _animationController.dispose(); _scrollController.dispose(); super.dispose(); }
  Color _parseColor(String hex) { try { hex = hex.replaceAll('#', ''); if (hex.length == 6) hex = 'FF$hex'; return Color(int.parse(hex, radix: 16)); } catch (_) { return Colors.white; } }
  @override
  Widget build(BuildContext context) {
    return Container(alignment: Alignment.centerLeft, child: SingleChildScrollView(controller: _scrollController, scrollDirection: Axis.horizontal, physics: const NeverScrollableScrollPhysics(), child: Row(children: [SizedBox(width: MediaQuery.of(context).size.width), Text(widget.text, style: TextStyle(fontSize: double.tryParse(widget.fontSize.toString()) ?? 24, color: _parseColor(widget.color), fontWeight: FontWeight.bold)), SizedBox(width: MediaQuery.of(context).size.width)])));
  }
}