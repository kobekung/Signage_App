// lib/widgets/content_player.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart'; // ✅ ใช้ Lib นี้ตามที่ขอครับ

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

  @override
  void initState() {
    super.initState();
    _initPlaylist();
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
      _playCurrentItem();
    }
  }

  void _playCurrentItem() async {
    if (!mounted) return;

    if (_currentIndex >= _playlist.length) {
      if (widget.isTriggerMode && widget.onFinished != null) {
        widget.onFinished!();
        return;
      } else {
        _currentIndex = 0;
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
    int duration = int.tryParse((item['duration'] ?? 10).toString()) ?? 10;

    Widget nextWidget;

    // ===========================
    // 🎥 VIDEO (Disposable - สร้างแล้วทิ้ง เพื่อคืน RAM)
    // ===========================
    if (type == 'video') {
      final url = item['url'];
      if (url == null) { _nextItem(); return; }

      File? cachedFile;
      try { cachedFile = await PreloadService.getCachedFile(url); } catch (_) {}

      nextWidget = _DisposableVideoPlayer(
        // วิดีโอยังคงใช้ UniqueKey เพื่อบังคับ Reset Decoder ทุกครั้งที่เล่น
        key: UniqueKey(), 
        file: cachedFile,
        url: url,
        isLooping: (!widget.isTriggerMode && _playlist.length == 1),
        onFinished: _nextItem,
      );
    } 
    // ===========================
    // 🖼️ NON-VIDEO
    // ===========================
    else {
      if (type == 'image') {
        final url = item['url'];
        File? cachedFile = await PreloadService.getCachedFile(url);
        nextWidget = cachedFile != null 
            ? Image.file(cachedFile, fit: BoxFit.cover)
            : Image.network(url, fit: BoxFit.cover);
      } 
      else if (type == 'webview') {
        final url = item['url'] ?? 'https://google.com';
        // 🔴 KEY FIX 1: ใช้ ValueKey(url) แทน UniqueKey()
        // ถ้า Playlist วนกลับมาที่เดิม หรือมี Item เดียว Flutter จะรู้ว่าเป็นอันเดิม
        // และจะไม่สั่ง Reload หน้าเว็บซ้ำครับ
        nextWidget = _WebviewItem(
          key: ValueKey(url), 
          url: url
        );
        duration = 15;
      } 
      else if (type == 'ticker') {
         nextWidget = _TickerItem(
          text: item['text'] ?? '',
          color: item['textColor'] ?? item['color'] ?? '#ffffff',
          fontSize: item['fontSize'] ?? 24,
          speed: item['speed'] ?? 50,
        );
        duration = 15;
      } else {
        nextWidget = Center(
          child: Text(item['text'] ?? '', style: const TextStyle(color: Colors.white, fontSize: 24)),
        );
      }

      Timer(Duration(seconds: duration), () {
        if (mounted) _nextItem();
      });
    }

    if (mounted) {
      setState(() {
        _currentContent = nextWidget;
      });
    }
  }

  void _nextItem() {
    _currentIndex++;
    _playCurrentItem();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: Colors.black,
      child: _currentContent ?? const SizedBox(),
    );
  }
}

// ==========================================
// 🌐 WebView Item (Watchdog Mode)
// ==========================================
class _WebviewItem extends StatefulWidget {
  final String url;
  const _WebviewItem({super.key, required this.url});

  @override
  State<_WebviewItem> createState() => _WebviewItemState();
}

class _WebviewItemState extends State<_WebviewItem> {
  WebViewController? _controller;
  StreamSubscription? _netSubscription;
  
  // สถานะ: เริ่มต้นถือว่ายังโหลดไม่สำเร็จ
  bool _loadSuccess = false; 

  @override
  void initState() {
    super.initState();
    _initWebView();
    _startWatchdog();
  }

  void _startWatchdog() {
    // 1. ดักจับการเปลี่ยนสถานะเน็ต (Offline -> Online)
    _netSubscription = Connectivity().onConnectivityChanged.listen((results) {
      bool hasConnection = results.any((r) => r != ConnectivityResult.none);
      if (hasConnection) {
        // เมื่อมีการเชื่อมต่อ ให้เช็คว่าต้องกู้คืนหน้าเว็บไหม
        _recoverIfNeeded();
      }
    });
  }

  Future<void> _recoverIfNeeded() async {
    // ✋ ถ้าโหลดสำเร็จอยู่แล้ว ไม่ต้องทำอะไร (ป้องกันรีเฟรชซ้ำ)
    if (_loadSuccess) return;

    // เช็ค Ping Google เพื่อความชัวร์ว่าออกเน็ตได้จริง
    bool hasRealNet = await _hasInternet();
    
    if (hasRealNet && mounted) {
      print("🌐 Internet back! Reloading WebView...");
      if (_controller != null) {
        _controller!.loadRequest(Uri.parse(widget.url));
      } else {
        _initWebView();
      }
    }
  }

  void _initWebView() {
    setState(() {
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0x00000000))
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (url) {
               // ✅ โหลดเสร็จจริง -> ล็อคสถานะ (เพื่อไม่ให้รีโหลดซ้ำ)
               if (mounted) setState(() => _loadSuccess = true);
            },
            onWebResourceError: (error) {
               // ❌ ถ้าเจอ Error ร้ายแรง -> ปลดล็อคสถานะ (เพื่อให้โอกาสโหลดใหม่เมื่อเน็ตมา)
               final desc = error.description.toLowerCase();
               final isCritical = desc.contains("net::err_internet_disconnected") || 
                                  desc.contains("net::err_name_not_resolved") ||
                                  desc.contains("net::err_address_unreachable") ||
                                  desc.contains("net::err_connection_timed_out");

               if (isCritical && mounted) {
                 setState(() => _loadSuccess = false);
                 // เมื่อสถานะเป็น false, ครั้งถัดไปที่ onConnectivityChanged ทำงาน มันจะสั่ง reload
               }
            },
          ),
        )
        ..loadRequest(Uri.parse(widget.url));
    });
  }

  Future<bool> _hasInternet() async {
    try {
      final result = await InternetAddress.lookup('google.com');
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  void dispose() {
    _netSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) { 
    if (_controller == null) {
      return const ColoredBox(color: Colors.black);
    }
    return WebViewWidget(controller: _controller!); 
  }
}

// ... ส่วน Video Player และ Ticker ใช้ของเดิมได้เลยครับ (มันเสถียรแล้ว)
// แต่เพื่อความครบถ้วน ผมใส่ Video Player Code (ตัวเดิมที่แก้ Resume แล้ว) ไว้ให้กันพลาดครับ

class _DisposableVideoPlayer extends StatefulWidget {
  final File? file;
  final String url;
  final bool isLooping;
  final VoidCallback onFinished;

  const _DisposableVideoPlayer({
    super.key,
    required this.file,
    required this.url,
    required this.isLooping,
    required this.onFinished,
  });

  @override
  State<_DisposableVideoPlayer> createState() => _DisposableVideoPlayerState();
}

class _DisposableVideoPlayerState extends State<_DisposableVideoPlayer> with WidgetsBindingObserver {
  late final Player player;
  late final VideoController controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
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
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) {
           setState(() {}); 
           player.play();
        }
      });
    }
  }

  Future<void> _init() async {
    player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 24 * 1024 * 1024,
        logLevel: MPVLogLevel.warn,
      ),
    );

    final native = player.platform as dynamic;
    if (native != null) {
      try {
        await native.setProperty('hwdec', 'mediacodec');
        await native.setProperty('hwdec-codecs', 'all');
        await native.setProperty('profile', 'fast');
        await native.setProperty('video-sync', 'audio');
      } catch (_) {}
    }

    controller = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
        androidAttachSurfaceAfterVideoParameters: true,
      ),
    );

    player.stream.completed.listen((isCompleted) {
      if (isCompleted && !widget.isLooping) {
        widget.onFinished();
      }
    });

    final media = widget.file != null ? Media(widget.file!.path) : Media(widget.url);
    await player.open(media, play: true);
    await player.setVolume(100.0);
    await player.setPlaylistMode(widget.isLooping ? PlaylistMode.single : PlaylistMode.none);

    player.stream.videoParams.listen((params) {
      if (params.w != null && params.h != null && !_ready) {
        if (mounted) setState(() => _ready = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const SizedBox();
    return Video(
      controller: controller,
      fit: BoxFit.cover,
      controls: NoVideoControls,
      fill: Colors.black,
    );
  }
}

// ... TickerWidget (Code เดิม)
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
  void dispose() { 
    _animationController.dispose(); 
    _scrollController.dispose(); 
    super.dispose(); 
  }

  Color _parseColor(String hex) { 
    try { 
      hex = hex.replaceAll('#', ''); 
      if (hex.length == 6) hex = 'FF$hex'; 
      return Color(int.parse(hex, radix: 16)); 
    } catch (_) { return Colors.white; } 
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.centerLeft, 
      child: SingleChildScrollView(
        controller: _scrollController, 
        scrollDirection: Axis.horizontal, 
        physics: const NeverScrollableScrollPhysics(), 
        child: Row(
          children: [
            SizedBox(width: MediaQuery.of(context).size.width), 
            Text(widget.text, style: TextStyle(fontSize: double.tryParse(widget.fontSize.toString()) ?? 24, color: _parseColor(widget.color), fontWeight: FontWeight.bold)), 
            SizedBox(width: MediaQuery.of(context).size.width)
          ]
        )
      )
    );
  }
}