// lib/widgets/content_player.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

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

  // ✅ แสดงจริงตัวไหน
  Widget? _currentContent;

  // ✅ กัน non-video timer ซ้อน
  Timer? _nonVideoTimer;

  // ✅ cache webview เพื่อไม่ให้ reload เมื่อกลับมาหน้าเดิม
  _WebviewHost? _cachedWebHost;
  String? _cachedWebUrl;

  // ✅ token กัน async เก่ามา setState ทับ
  int _playToken = 0;

  @override
  void initState() {
    super.initState();
    _initPlaylist();
  }

  @override
  void dispose() {
    _nonVideoTimer?.cancel();
    super.dispose();
  }

  void _initPlaylist() {
    final props = widget.widget.properties;

    if (props['playlist'] != null && (props['playlist'] as List).isNotEmpty) {
      _playlist = List.from(props['playlist']);
    } else if (props['url'] != null || props['text'] != null) {
      _playlist = [
        {
          'url': props['url'] ?? '',
          'text': props['text'] ?? props['content'],
          'type': widget.widget.type,
          'duration': 10,
          ...props,
        }
      ];
    }

    if (_playlist.isNotEmpty) {
      _playCurrentItem();
    }
  }

  Future<void> _playCurrentItem() async {
    if (!mounted) return;

    final int token = ++_playToken;

    // ✅ กัน Timer เก่าทับซ้อน
    _nonVideoTimer?.cancel();
    _nonVideoTimer = null;

    if (_currentIndex >= _playlist.length) {
      if (widget.isTriggerMode && widget.onFinished != null) {
        widget.onFinished!();
        return;
      } else {
        _currentIndex = 0;
      }
    }

    final item = _playlist[_currentIndex];

    // fullscreen callback
    final isFull = item['fullscreen'] == true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.onFullscreenChange != null && mounted) {
        widget.onFullscreenChange!(isFull);
      }
    });

    final type = item['type'] ?? widget.widget.type;
    int duration = int.tryParse((item['duration'] ?? 10).toString()) ?? 10;

    // ===========================
    // 🎥 VIDEO
    // ===========================
    if (type == 'video') {
      final url = item['url'];
      if (url == null || (url is String && url.trim().isEmpty)) {
        _nextItem();
        return;
      }

      File? cachedFile;
      try {
        cachedFile = await PreloadService.getCachedFile(url);
      } catch (_) {}

      final videoWidget = _DisposableVideoPlayer(
        key: UniqueKey(), // reset decoder
        file: cachedFile,
        url: url.toString(),
        isLooping: (!widget.isTriggerMode && _playlist.length == 1),
        onFinished: _nextItem,
      );

      // ✅ ใส่ widget ทันที (สำคัญมาก)
      setState(() => _currentContent = videoWidget);
      return;
    }

    // ===========================
    // 🖼️ IMAGE / WEBVIEW / TICKER / TEXT
    // ===========================
    Widget nextWidget;

    if (type == 'image') {
      final url = item['url'];
      if (url == null || (url is String && url.trim().isEmpty)) {
        nextWidget = const SizedBox();
      } else {
        File? cachedFile;
        try {
          cachedFile = await PreloadService.getCachedFile(url);
        } catch (_) {}

        nextWidget = cachedFile != null
            ? Image.file(cachedFile, fit: BoxFit.cover)
            : Image.network(url.toString(), fit: BoxFit.cover);
      }
    } else if (type == 'webview') {
      final url = (item['url'] ?? 'https://google.com').toString();

      // ✅ สำคัญ: ห้าม drop เป็น SizedBox() ก่อน
      // ✅ ใช้ cache เพื่อไม่ destroy webview (ไม่ reload เมื่อกลับมา)
      if (_cachedWebHost == null || _cachedWebUrl != url) {
        _cachedWebUrl = url;
        _cachedWebHost = _WebviewHost(url: url);
      }

      nextWidget = _cachedWebHost!;
      duration = 15;
    } else if (type == 'ticker') {
      nextWidget = _TickerItem(
        text: item['text'] ?? '',
        color: item['textColor'] ?? item['color'] ?? '#ffffff',
        fontSize: item['fontSize'] ?? 24,
        speed: item['speed'] ?? 50,
      );
      duration = 15;
    } else {
      nextWidget = Center(
        child: Text(
          item['text'] ?? '',
          style: const TextStyle(color: Colors.white, fontSize: 24),
        ),
      );
    }

    if (!mounted || token != _playToken) return;
    setState(() => _currentContent = nextWidget);

    _nonVideoTimer = Timer(Duration(seconds: duration), () {
      if (mounted && token == _playToken) _nextItem();
    });
  }

  void _nextItem() {
    _nonVideoTimer?.cancel();
    _nonVideoTimer = null;

    _currentIndex++;
    _playCurrentItem();
  }

  @override
  Widget build(BuildContext context) {
    // ✅ ถ้าอยาก “ให้ WebView หยุด render ตอนซ่อน” ให้ใช้ Stack + Offstage
    // ปัจจุบันแบบง่าย: สลับ child ปกติ (WebView จะยังอยู่ถ้า cache ไว้)
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: Colors.black,
      child: _currentContent ?? const SizedBox(),
    );
  }
}

// ==========================================
// 🌐 WebView Host (Smart Health Check)
// ==========================================
class _WebviewHost extends StatefulWidget {
  final String url;
  const _WebviewHost({super.key, required this.url});

  @override
  State<_WebviewHost> createState() => _WebviewHostState();
}

class _WebviewHostState extends State<_WebviewHost> with WidgetsBindingObserver {
  WebViewController? _controller;
  Timer? _healthCheckTimer;
  
  // สถานะการทำงาน
  bool _hasInternet = false;    // เน็ตมายัง?
  bool _isPageLoaded = false;   // โหลดหน้าเว็บเสร็จยัง?
  bool _isInit = false;         // WebView สร้างเสร็จยัง?

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initWebView();
    
    // ✅ เริ่มระบบเช็คชีพจรเน็ตทันที
    _startHealthCheck();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _healthCheckTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // แอปตื่นมา รีเซ็ตค่าแล้วเช็คใหม่ทันที
      setState(() {
         _hasInternet = false;
         _isPageLoaded = false;
      });
      _startHealthCheck();
    }
  }

  void _initWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF000000)) // พื้นหลังดำ
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            // โหลดเสร็จจริง -> ปลดตัวโหลดออก
            if (mounted) setState(() => _isPageLoaded = true);
          },
          onWebResourceError: (error) {
            // ถ้า WebView แจ้งว่าพัง ให้ถือว่าเน็ตหลุด
            print("WebView Error: ${error.description}");
            if (mounted && _isPageLoaded) {
               setState(() => _isPageLoaded = false);
            }
          },
        ),
      );
      // ยังไม่สั่ง loadRequest ตรงนี้! รอให้เช็คเน็ตผ่านก่อน
      setState(() => _isInit = true);
  }

  // 🔄 เช็คเน็ตทุกๆ 5 วินาที (Ping Google)
  void _startHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }

      bool status = await _checkInternet();

      // ถ้าสถานะเน็ตเปลี่ยน (จากไม่มี -> มี หรือ จากมี -> ไม่มี)
      if (status != _hasInternet) {
        setState(() => _hasInternet = status);
        
        if (status) {
          // 🎉 เน็ตมาแล้ว! สั่งโหลดเว็บเลย
          print("🌐 Internet is BACK! Loading WebView...");
          _controller?.loadRequest(Uri.parse(widget.url));
        } else {
          // 💀 เน็ตหลุด!
          print("❌ Internet LOST!");
          // (Optional) อาจจะสั่ง clearCache หรือทำอะไรก็ได้
        }
      } 
      // กรณีพิเศษ: เน็ตมี (status=true) แต่หน้าเว็บยังหมุนไม่เสร็จ (อาจจะค้าง) -> สั่งโหลดซ้ำ
      else if (status && !_isPageLoaded) {
         print("🌐 Internet OK but Page not loaded... Retrying...");
         _controller?.loadRequest(Uri.parse(widget.url));
      }
    });
    
    // รันครั้งแรกทันทีไม่ต้องรอ 5 วิ
    _checkInternet().then((status) {
       if (mounted && status) {
          setState(() => _hasInternet = true);
          _controller?.loadRequest(Uri.parse(widget.url));
       }
    });
  }

  // ยิง DNS Lookup เพื่อเช็คว่าออกเน็ตได้จริงไหม
  Future<bool> _checkInternet() async {
    try {
      final result = await InternetAddress.lookup('google.com');
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  void didUpdateWidget(covariant _WebviewHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      setState(() => _isPageLoaded = false);
      if (_hasInternet) {
        _controller?.loadRequest(Uri.parse(widget.url));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // ถ้ายัง Init ไม่เสร็จ หรือ ไม่มีเน็ต หรือ หน้าเว็บยังโหลดไม่เสร็จ
    // ให้แสดง Loading Screen บังไว้เลย (User จะไม่เห็นหน้า Error ไดโนเสาร์)
    bool showLoading = !_isInit || !_hasInternet || !_isPageLoaded;

    return Stack(
      children: [
        if (_isInit && _controller != null)
           WebViewWidget(controller: _controller!),

        if (showLoading)
          Container(
            color: Colors.black, // พื้นหลังดำสนิท
            width: double.infinity,
            height: double.infinity,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                CircularProgressIndicator(color: Colors.white),
                SizedBox(height: 20),
                Text(
                  "Waiting for connection...",
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ==========================================
// 🎥 Video Player (Android TV Safe Mode + Watchdog)
// ==========================================
class _DisposableVideoPlayer extends StatefulWidget {
  final File? file;
  final String url;
  final bool isLooping;
  final VoidCallback onFinished;
  final VoidCallback? onReady;

  const _DisposableVideoPlayer({
    super.key,
    required this.file,
    required this.url,
    required this.isLooping,
    required this.onFinished,
    this.onReady,
  });

  @override
  State<_DisposableVideoPlayer> createState() => _DisposableVideoPlayerState();
}

class _DisposableVideoPlayerState extends State<_DisposableVideoPlayer>
    with WidgetsBindingObserver {
  Player? _player;
  VideoController? _controller;
  bool _ready = false;

  Timer? _stuckWatchdog;
  StreamSubscription? _completedSub;
  StreamSubscription? _videoParamsSub;

  // 🔥 WATCHDOG VARIABLES 🔥
  Timer? _freezeWatchdog;
  Duration _lastPosition = Duration.zero;
  int _freezeCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();

    // ✅ เริ่มระบบยามเฝ้าจอ
    _startWatchdog();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    _freezeWatchdog?.cancel();
    _stuckWatchdog?.cancel();
    _completedSub?.cancel();
    _videoParamsSub?.cancel();

    _player?.dispose();
    _player = null;
    _controller = null;

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (!mounted) return;
        _recreatePlayer(reason: "resume");
      });
    }
  }

  void _startWatchdog() {
    _freezeWatchdog?.cancel();
    _freezeWatchdog = Timer.periodic(const Duration(seconds: 4), (timer) {
      if (!mounted || _player == null) return;

      final state = _player!.state;
      
      // เงื่อนไขหลัก: ต้องกำลังเล่น และ ไม่ได้หมุนติ้ว
      if (state.playing && !state.buffering) {
        
        // -----------------------------------------------------
        // 1. เช็คค้าง (Time Freeze) - อันเดิม
        // -----------------------------------------------------
        final currentPos = state.position;
        bool isTimeFrozen = (currentPos - _lastPosition).abs().inMilliseconds < 100;

        // -----------------------------------------------------
        // 2. เช็คจอดำแบบอ้อมๆ (Dimensions Error) - อันใหม่ 🔥
        // -----------------------------------------------------
        // ถ้าเล่นอยู่ แต่ความกว้าง/สูงของวิดีโอเป็น 0 หรือ null แปลว่า Decoder พัง (ภาพไม่มาแน่ๆ)
        bool isDimensionInvalid = (state.width == null || state.width == 0 || 
                                   state.height == null || state.height == 0);

        // รวมมิตรความผิดปกติ
        if (isTimeFrozen || isDimensionInvalid) {
          _freezeCount++;
          
          if (isDimensionInvalid) {
             print("⚠️ Warning: Video dimensions are 0x0 (Black Screen potential)");
          }
        } else {
          _freezeCount = 0; // ปกติสุข
          _lastPosition = currentPos;
        }

        // 🔥 ถ้าผิดปกติครบ 3 รอบ (15 วินาที) -> สั่งรีเซ็ต
        if (_freezeCount >= 2) {
          String cause = isDimensionInvalid ? "black-screen-0x0" : "freeze-detected";
          print("🚨 PROBLEM DETECTED ($cause)! Restarting Player...");
          
          _freezeCount = 0;
          _recreatePlayer(reason: cause);
        }
      }
    });
  }

  Future<void> _recreatePlayer({required String reason}) async {
    _freezeWatchdog?.cancel(); // หยุดยามชั่วคราว
    _stuckWatchdog?.cancel();
    _completedSub?.cancel();
    _videoParamsSub?.cancel();

    _player?.dispose();
    _player = null;
    _controller = null;

    if (mounted) setState(() => _ready = false);

    await Future.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
    
    await _init();
    
    // เริ่มยามใหม่
    _startWatchdog();
  }

  Future<void> _init() async {
    final p = Player(
      configuration: const PlayerConfiguration(
        // ✅ ลด Buffer ลงเหลือ 16MB (ปลอดภัยสำหรับ mediacodec-copy บน Rockchip)
        bufferSize: 16 * 1024 * 1024, 
        logLevel: MPVLogLevel.warn,
      ),
    );
    _player = p;

    final native = p.platform as dynamic;
    if (native != null) {
      try {
        // 🔥 Config สูตร Rockchip RK3576 + Android 14 (Long Run Stability)
        
        // 1. ใช้ Copy เพื่อแก้จอดำและป้องกัน VPU ค้าง
        await native.setProperty('hwdec', 'no'); 
        
        // ✅ ปรับจูน Software Decode ให้เบาเครื่องที่สุด
        await native.setProperty('profile', 'fast');
        await native.setProperty('video-sync', 'audio');
        await native.setProperty('vd-lavc-threads', '4');
      } catch (_) {}
    }

    _controller = VideoController(
      p,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
        androidAttachSurfaceAfterVideoParameters: true,
      ),
    );

    _completedSub = p.stream.completed.listen((isCompleted) {
      if (isCompleted && !widget.isLooping) {
        widget.onFinished();
      }
    });

    _videoParamsSub = p.stream.videoParams.listen((params) {
      if (params.w != null && params.h != null && !_ready) {
        _ready = true;
        if (mounted) setState(() {});
        widget.onReady?.call();
      }
    });

    _stuckWatchdog?.cancel();
    _stuckWatchdog = Timer(const Duration(seconds: 6), () {
      if (!mounted) return;
      if (!_ready) {
        _recreatePlayer(reason: "stuck-watchdog");
      }
    });

    final media = widget.file != null ? Media(widget.file!.path) : Media(widget.url);
    await p.open(media, play: true);
    await p.setVolume(100.0);
    await p.setPlaylistMode(widget.isLooping ? PlaylistMode.single : PlaylistMode.none);
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c == null) return const SizedBox();

    return Video(
      controller: c,
      fit: BoxFit.cover,
      controls: NoVideoControls,
      fill: Colors.black,
    );
  }
}

// ==========================================
// 📰 Ticker (เดิม)
// ==========================================
class _TickerItem extends StatefulWidget {
  final String text;
  final String color;
  final dynamic fontSize;
  final dynamic speed;
  const _TickerItem({
    required this.text,
    required this.color,
    this.fontSize,
    this.speed,
  });

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
    _animationController =
        AnimationController(vsync: this, duration: const Duration(seconds: 10));
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
    } catch (_) {
      return Colors.white;
    }
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
            Text(
              widget.text,
              style: TextStyle(
                fontSize: double.tryParse(widget.fontSize.toString()) ?? 24,
                color: _parseColor(widget.color),
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(width: MediaQuery.of(context).size.width),
          ],
        ),
      ),
    );
  }
}