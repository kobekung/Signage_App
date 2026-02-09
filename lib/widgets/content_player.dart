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

// ==========================================
// 🔧 การตั้งค่าหลัก - แก้ตรงนี้
// ==========================================
class VideoConfig {
  // 🎚️ เปิด/ปิด Watchdog
  static const bool ENABLE_WATCHDOG = true; // 👈 false = ปิด, true = เปิด
  
  // 🎬 ตั้งค่า Hardware Decode
  // ทดสอบตามลำดับ: 'mediacodec-copy' → 'no' → 'mediacodec'
  static const String HWDEC_MODE = 'mediacodec-copy'; // 👈 เปลี่ยนตรงนี้
  
  // 📦 Buffer Size (แนะนำ: 64MB หรือ 128MB)
  static const int BUFFER_SIZE_MB = 128; // 👈 16, 32, 64, 128
  
  // 🔍 แสดง Debug Logs
  static const bool SHOW_DEBUG_LOGS = true; // 👈 true = เปิด, false = ปิด
}

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
  Timer? _nonVideoTimer;
  _WebviewHost? _cachedWebHost;
  String? _cachedWebUrl;
  int _playToken = 0;

  @override
  void initState() {
    super.initState();
    _initPlaylist();
    
    if (VideoConfig.SHOW_DEBUG_LOGS) {
      print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      print("📺 VIDEO PLAYER CONFIG");
      print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      print("🔧 Watchdog: ${VideoConfig.ENABLE_WATCHDOG ? 'ENABLED ✅' : 'DISABLED ❌'}");
      print("🎬 HW Decode: ${VideoConfig.HWDEC_MODE}");
      print("📦 Buffer: ${VideoConfig.BUFFER_SIZE_MB}MB");
      print("🔍 Debug Logs: ${VideoConfig.SHOW_DEBUG_LOGS ? 'ON' : 'OFF'}");
      print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
    }
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
    final isFull = item['fullscreen'] == true;
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.onFullscreenChange != null && mounted) {
        widget.onFullscreenChange!(isFull);
      }
    });

    final type = item['type'] ?? widget.widget.type;
    int duration = int.tryParse((item['duration'] ?? 10).toString()) ?? 10;

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
        key: UniqueKey(),
        file: cachedFile,
        url: url.toString(),
        isLooping: (!widget.isTriggerMode && _playlist.length == 1),
        onFinished: _nextItem,
      );

      setState(() => _currentContent = videoWidget);
      return;
    }

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
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: Colors.black,
      child: _currentContent ?? const SizedBox(),
    );
  }
}

// ==========================================
// 🌐 WebView Host
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
  bool _hasInternet = false;
  bool _isPageLoaded = false;
  bool _isInit = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initWebView();
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
      ..setBackgroundColor(const Color(0xFF000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) setState(() => _isPageLoaded = true);
          },
          onWebResourceError: (error) {
            if (VideoConfig.SHOW_DEBUG_LOGS) {
              print("WebView Error: ${error.description}");
            }
            if (mounted && _isPageLoaded) {
               setState(() => _isPageLoaded = false);
            }
          },
        ),
      );
      setState(() => _isInit = true);
  }

  void _startHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }

      bool status = await _checkInternet();

      if (status != _hasInternet) {
        setState(() => _hasInternet = status);
        
        if (status) {
          if (VideoConfig.SHOW_DEBUG_LOGS) {
            print("🌐 Internet BACK! Loading WebView...");
          }
          _controller?.loadRequest(Uri.parse(widget.url));
        } else {
          if (VideoConfig.SHOW_DEBUG_LOGS) {
            print("❌ Internet LOST!");
          }
        }
      } 
      else if (status && !_isPageLoaded) {
         if (VideoConfig.SHOW_DEBUG_LOGS) {
           print("🌐 Retrying WebView...");
         }
         _controller?.loadRequest(Uri.parse(widget.url));
      }
    });
    
    _checkInternet().then((status) {
       if (mounted && status) {
          setState(() => _hasInternet = true);
          _controller?.loadRequest(Uri.parse(widget.url));
       }
    });
  }

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
    bool showLoading = !_isInit || !_hasInternet || !_isPageLoaded;

    return Stack(
      children: [
        if (_isInit && _controller != null)
           WebViewWidget(controller: _controller!),

        if (showLoading)
          Container(
            color: Colors.black,
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
// 🎥 Video Player (Fixed Version)
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
  Timer? _freezeWatchdog;
  StreamSubscription? _completedSub;
  StreamSubscription? _videoParamsSub;

  Duration _lastPosition = Duration.zero;
  int _freezeCount = 0;
  int _bufferingCount = 0; // 🆕 เพิ่ม

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();

    if (VideoConfig.ENABLE_WATCHDOG) {
      _startWatchdog();
      if (VideoConfig.SHOW_DEBUG_LOGS) {
        print("🔥 Watchdog: ENABLED");
      }
    } else {
      if (VideoConfig.SHOW_DEBUG_LOGS) {
        print("⚠️ Watchdog: DISABLED");
      }
    }
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
    // 🔧 แก้ไข: ไม่ Recreate ทันทีตอน Resume
    if (state == AppLifecycleState.resumed) {
      if (VideoConfig.SHOW_DEBUG_LOGS) {
        print("📱 App resumed - resuming playback");
      }
      // แค่เล่นต่อ ไม่ต้อง Recreate
      _player?.play();
    }
  }

  void _startWatchdog() {
    _freezeWatchdog?.cancel();
    
    _freezeWatchdog = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (!mounted || _player == null) return;

      final state = _player!.state;
      
      if (state.playing) {
        
        // 🆕 เช็ค Buffering นานเกินไป
        if (state.buffering) {
          _bufferingCount++;
          if (_bufferingCount > 5) { // 10 วินาที
            if (VideoConfig.SHOW_DEBUG_LOGS) {
              print("⚠️ Buffering too long (${_bufferingCount * 2}s)");
            }
            _bufferingCount = 0;
            _recreatePlayer(reason: "stuck-buffering");
            return;
          }
        } else {
          _bufferingCount = 0;
        }
        
        // เช็ค Time Freeze
        final currentPos = state.position;
        bool isTimeFrozen = !state.buffering && 
                            (currentPos - _lastPosition).abs().inMilliseconds < 100;

        // เช็ค Dimension Invalid
        bool isDimensionInvalid = (state.width == null || state.width == 0 || 
                                   state.height == null || state.height == 0);

        if (isTimeFrozen || isDimensionInvalid) {
          _freezeCount++;
          
          if (VideoConfig.SHOW_DEBUG_LOGS) {
            if (isDimensionInvalid) {
               print("⚠️ Warning [${_freezeCount}x]: Dimensions 0x0");
            } else {
               print("⚠️ Warning [${_freezeCount}x]: Time frozen at ${currentPos.inSeconds}s");
            }
          }
        } else {
          if (_freezeCount > 0 && VideoConfig.SHOW_DEBUG_LOGS) {
            print("✅ Video recovered!");
          }
          _freezeCount = 0;
          _lastPosition = currentPos;
        }

        if (_freezeCount >= 1) {
          String cause = isDimensionInvalid ? "black-screen" : "time-freeze";
          if (VideoConfig.SHOW_DEBUG_LOGS) {
            print("🚨 CRITICAL: $cause! Restarting...");
          }
          
          _freezeCount = 0;
          _recreatePlayer(reason: cause);
        }
      } else {
        _freezeCount = 0;
        _bufferingCount = 0;
      }
    });
  }

  Future<void> _recreatePlayer({required String reason}) async {
    if (VideoConfig.SHOW_DEBUG_LOGS) {
      print("🔄 Recreating player... Reason: $reason");
    }
    
    _freezeWatchdog?.cancel();
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
    
    if (VideoConfig.ENABLE_WATCHDOG) {
      _startWatchdog();
    }
  }

  Future<void> _init() async {
    // 🔧 แก้ไข 1: เพิ่ม Buffer Size
    final bufferBytes = VideoConfig.BUFFER_SIZE_MB * 1024 * 1024;
    
    final p = Player(
      configuration: PlayerConfiguration(
        bufferSize: bufferBytes, // 🔥 ใช้ค่าจาก Config
        logLevel: MPVLogLevel.warn,
      ),
    );
    _player = p;

    final native = p.platform as dynamic;
    if (native != null) {
      try {
        // 🔧 แก้ไข 2: hwdec พร้อม Fallback
        try {
          await native.setProperty('hwdec', VideoConfig.HWDEC_MODE);
        } catch (e) {
          if (VideoConfig.SHOW_DEBUG_LOGS) {
            print("⚠️ hwdec failed, fallback to software");
          }
          await native.setProperty('hwdec', 'no');
        }
        
        // 🔧 แก้ไข 3: ปรับ Thread ตาม hwdec
        if (VideoConfig.HWDEC_MODE == 'no') {
          await native.setProperty('vd-lavc-threads', '8'); // Software ใช้เต็ม
          // เพิ่มการ Skip Frame สำหรับ Software
          await native.setProperty('vd-lavc-skiploopfilter', 'all');
          await native.setProperty('vd-lavc-skipframe', 'nonref');
          await native.setProperty('vd-lavc-fast', 'yes');
        } else {
          await native.setProperty('vd-lavc-threads', '2'); // Hardware ใช้น้อย
        }
        
        await native.setProperty('profile', 'fast');
        
        // 🔧 แก้ไข 4: เปลี่ยน video-sync
        await native.setProperty('video-sync', 'display-resample');
        
        // 🔧 แก้ไข 5: เพิ่ม Cache Settings
        await native.setProperty('cache', 'yes');
        await native.setProperty('cache-secs', '10');
        await native.setProperty('demuxer-max-bytes', '${VideoConfig.BUFFER_SIZE_MB}M');
        await native.setProperty('demuxer-readahead-secs', '5');
        
        if (VideoConfig.SHOW_DEBUG_LOGS) {
          print("🎬 Player initialized:");
          print("   - hwdec: ${VideoConfig.HWDEC_MODE}");
          print("   - buffer: ${VideoConfig.BUFFER_SIZE_MB}MB");
          print("   - threads: ${VideoConfig.HWDEC_MODE == 'no' ? '8' : '2'}");
          print("   - cache: 10s + ${VideoConfig.BUFFER_SIZE_MB}MB");
        }
      } catch (e) {
        if (VideoConfig.SHOW_DEBUG_LOGS) {
          print("❌ Init properties failed: $e");
        }
      }
    }

    // 🔧 แก้ไข 6: ทดสอบปิด androidAttachSurfaceAfterVideoParameters
    _controller = VideoController(
      p,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
        androidAttachSurfaceAfterVideoParameters: false, // 🔥 เปลี่ยนเป็น false
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
        if (VideoConfig.SHOW_DEBUG_LOGS) {
          print("✅ Video ready: ${params.w}x${params.h}");
        }
        if (mounted) setState(() {});
        widget.onReady?.call();
      }
    });

    // 🔧 แก้ไข 7: เพิ่ม Init Timeout
    _stuckWatchdog?.cancel();
    _stuckWatchdog = Timer(const Duration(seconds: 10), () { // 6 → 10 วิ
      if (!mounted) return;
      if (!_ready) {
        if (VideoConfig.SHOW_DEBUG_LOGS) {
          print("⏱️ Init timeout (10s)");
        }
        _recreatePlayer(reason: "init-timeout");
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
// 📰 Ticker
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