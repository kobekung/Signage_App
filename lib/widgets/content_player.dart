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

    // เช็คว่าเล่นจบ Playlist หรือยัง
    if (_currentIndex >= _playlist.length) {
      if (widget.isTriggerMode && widget.onFinished != null) {
        widget.onFinished!(); // จบงาน Trigger
        return; 
      } else {
        _currentIndex = 0; // วนลูปกลับไปเริ่มใหม่
      }
    }

    final item = _playlist[_currentIndex];
    
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

    // --- VIDEO (MEDIA KIT) ---
    if (type == 'video') {
      final url = item['url'];
      File? cachedFile = await PreloadService.getCachedFile(url);
      
      bool shouldLoop = !widget.isTriggerMode && _playlist.length == 1;

      content = _MediaKitVideoItem(
        key: ValueKey("$url-$_currentIndex"), 
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
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: Colors.black, 
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 800),
        layoutBuilder: (currentChild, previousChildren) {
          return Stack(
            fit: StackFit.expand,
            alignment: Alignment.center,
            children: [
              ...previousChildren, 
              if (currentChild != null) currentChild,
            ],
          );
        },
        transitionBuilder: (Widget child, Animation<double> animation) {
          return FadeTransition(opacity: animation, child: child);
        },
        child: _currentContent ?? const SizedBox(),
      ),
    );
  }
}

// ==========================================
// 📽️ MediaKit Video Player Widget (Fixed Freeze Issue)
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

// [FIX] เพิ่ม WidgetsBindingObserver เพื่อดักจับสถานะแอป
// ... (ส่วน import อื่นๆ เหมือนเดิม)

// คลาส _MediaKitVideoItemState แก้ไขดังนี้
class _MediaKitVideoItemState extends State<_MediaKitVideoItem> with WidgetsBindingObserver {
  // [PERFORMANCE] 1. เพิ่ม Configuration เพื่อลดอาการแลค
  late final Player player = Player(
    configuration: const PlayerConfiguration(
      // เพิ่ม Buffer เป็น 32MB (ช่วยลดกระตุกเวลาอ่านไฟล์ไม่ทัน)
      bufferSize: 32 * 1024 * 1024, 
      // บังคับใช้ log level เพื่อดู error ถ้ามี
      logLevel: MPVLogLevel.warn,
    ),
  );
  
  late final VideoController controller = VideoController(player);
  
  bool _isVideoReady = false; 

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initPlayer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // [FIX] ต้อง dispose player เสมอเพื่อคืน RAM
    player.dispose(); 
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      if (!player.state.playing) {
         // บังคับเล่นต่อถ้าแอพโดนบัง
         player.play();
      }
    }
  }

  Future<void> _initPlayer() async {
    try {
      final Media media = widget.file != null 
          ? Media(widget.file!.path) 
          : Media(widget.url);

      await player.open(media, play: true);
      
      // [FIX AUDIO] 2. แก้ปัญหาเสียงไม่ออก
      await player.setVolume(100.0); // บังคับเปิดเสียง 100%
      await player.setAudioTrack(AudioTrack.auto()); // เลือก Track เสียงอัตโนมัติ

      // [PERFORMANCE] 3. ตั้งค่า Loop แบบ Native เพื่อความลื่นไหล
      await player.setPlaylistMode(widget.isLooping ? PlaylistMode.single : PlaylistMode.none);

      player.stream.videoParams.listen((params) {
        // เช็คว่ามีภาพมาแล้วจริงๆ
        if (params.w != null && params.h != null && !_isVideoReady) {
          if (mounted) setState(() => _isVideoReady = true);
        }
      });

      // Timeout กันเหนียว ถ้าโหลดนานเกิน 1 วิ ให้โชว์เลย (ป้องกันจอดำนาน)
      Future.delayed(const Duration(milliseconds: 1000), () {
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
        print("❌ MediaKit Error: $error");
        // ถ้า error ให้ข้ามไปไฟล์ถัดไปเลย
        widget.onFinished();
      });

    } catch (e) {
      print("Init Error: $e");
      widget.onFinished();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      // ปรับเวลา Fade ให้เร็วขึ้นเล็กน้อยเพื่อให้รู้สึกทันใจขึ้น (จากเดิมอาจจะช้าไป)
      opacity: _isVideoReady ? 1.0 : 0.0, 
      duration: const Duration(milliseconds: 300), 
      child: Video(
        controller: controller,
        fit: BoxFit.cover,
        controls: NoVideoControls,
        // ใช้สีดำแทน transparent เพื่อป้องกันภาพกระพริบ
        fill: Colors.black, 
      ),
    );
  }
}

// --- Sub Widgets (คงเดิม) ---

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