// lib/widgets/content_player.dart
// 🎯 Version: Root Cause Fix (No Watchdog Dependency)
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
// 🔧 การตั้งค่าหลัก
// ==========================================
class VideoConfig {
  // 🎚️ Watchdog (ตรวจจับจอค้าง)
  static const bool ENABLE_WATCHDOG = true;
  
  // 🎬 Hardware Decode (ทดสอบ 'no' ก่อน!)
  static const String HWDEC_MODE = 'no'; // 👈 เริ่มจาก Software
  
  // 📦 Buffer (เพิ่มขึ้น)
  static const int BUFFER_SIZE_MB = 64; // 👈 เพิ่มเป็น 128MB
  
  // 🔄 Preventive Restart (ป้องกันค้าง)
  static const bool ENABLE_PREVENTIVE_RESTART = true; // 👈 เปิด
  static const int RESTART_INTERVAL_MINUTES = 15; // ทุก 15 นาที
  
  // 🧹 Cache Flush (แก้ Memory Leak)
  static const bool ENABLE_CACHE_FLUSH = true; // 👈 เปิด
  static const int FLUSH_INTERVAL_MINUTES = 5; // ทุก 5 นาที
  
  // 🌡️ Temperature Monitor
  static const bool ENABLE_TEMP_MONITOR = true; // 👈 เปิด
  static const int TEMP_CHECK_SECONDS = 30; // ทุก 30 วิ
  static const int MAX_TEMP_CELSIUS = 75; // เตือนที่ 75°C
  
  // 🔍 Debug
  static const bool SHOW_DEBUG_LOGS = true;
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
      print("📺 ROOT CAUSE FIX MODE");
      print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      print("🎬 HW Decode: ${VideoConfig.HWDEC_MODE}");
      print("📦 Buffer: ${VideoConfig.BUFFER_SIZE_MB}MB");
      print("🔄 Preventive Restart: ${VideoConfig.ENABLE_PREVENTIVE_RESTART ? 'YES' : 'NO'} (${VideoConfig.RESTART_INTERVAL_MINUTES}min)");
      print("🧹 Cache Flush: ${VideoConfig.ENABLE_CACHE_FLUSH ? 'YES' : 'NO'} (${VideoConfig.FLUSH_INTERVAL_MINUTES}min)");
      print("🌡️ Temp Monitor: ${VideoConfig.ENABLE_TEMP_MONITOR ? 'YES' : 'NO'}");
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
    
    // 🔥 รอให้ Dispose เสร็จก่อนเล่นใหม่ (แก้ Memory Leak)
    if (_currentContent is _DisposableVideoPlayer) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) {
          _currentIndex++;
          _playCurrentItem();
        }
      });
    } else {
      _currentIndex++;
      _playCurrentItem();
    }
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
          _controller?.loadRequest(Uri.parse(widget.url));
        }
      } 
      else if (status && !_isPageLoaded) {
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
// 🎥 Video Player (Root Cause Fix)
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

  // Timers
  Timer? _initCheckTimer;
  Timer? _freezeWatchdog;
  Timer? _preventiveRestartTimer; // 🆕
  Timer? _cacheFlushTimer; // 🆕
  Timer? _tempMonitorTimer; // 🆕
  
  StreamSubscription? _completedSub;
  StreamSubscription? _videoParamsSub;

  // Counters
  int _initCheckCount = 0;
  Duration _lastPosition = Duration.zero;
  int _freezeCount = 0;
  int _bufferingCount = 0;
  DateTime _playerStartTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _playerStartTime = DateTime.now();
    _init();

    if (VideoConfig.ENABLE_WATCHDOG) {
      _startWatchdog();
    }
    
    // 🔥 เริ่ม Preventive Measures
    if (VideoConfig.ENABLE_PREVENTIVE_RESTART) {
      _startPreventiveRestart();
    }
    
    if (VideoConfig.ENABLE_CACHE_FLUSH) {
      _startCacheFlush();
    }
    
    if (VideoConfig.ENABLE_TEMP_MONITOR) {
      _startTempMonitor();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _initCheckTimer?.cancel();
    _freezeWatchdog?.cancel();
    _preventiveRestartTimer?.cancel();
    _cacheFlushTimer?.cancel();
    _tempMonitorTimer?.cancel();
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
      _player?.play();
    }
  }

  // 🔄 Preventive Restart (แก้ MediaCodec Crash)
  void _startPreventiveRestart() {
    // สำหรับ looping video ใช้ interval ยาวกว่า (30 นาที) เพื่อลด disruption
    final minutes = widget.isLooping
        ? VideoConfig.RESTART_INTERVAL_MINUTES * 2
        : VideoConfig.RESTART_INTERVAL_MINUTES;
    final interval = Duration(minutes: minutes);

    _preventiveRestartTimer = Timer.periodic(interval, (timer) {
      if (!mounted) return;

      final elapsed = DateTime.now().difference(_playerStartTime);
      if (VideoConfig.SHOW_DEBUG_LOGS) {
        print("🔄 Preventive restart after ${elapsed.inMinutes} minutes (looping=${widget.isLooping})");
      }

      _recreatePlayer(reason: "preventive-${minutes}min");
    });
  }

  // 🧹 Cache Flush (แก้ Memory Leak)
  void _startCacheFlush() {
    final interval = Duration(minutes: VideoConfig.FLUSH_INTERVAL_MINUTES);
    
    _cacheFlushTimer = Timer.periodic(interval, (timer) async {
      if (!mounted || _player == null) return;
      
      final native = _player!.platform as dynamic;
      if (native != null) {
        try {
          // ล้าง Demuxer Cache
          await native.command(['vf', 'lavfi', '[buffer=0]']);
          
          if (VideoConfig.SHOW_DEBUG_LOGS) {
            print("🧹 Cache flushed (${VideoConfig.FLUSH_INTERVAL_MINUTES} min)");
          }
        } catch (e) {
          if (VideoConfig.SHOW_DEBUG_LOGS) {
            print("⚠️ Cache flush failed: $e");
          }
        }
      }
    });
  }

  // 🌡️ Temperature Monitor (แก้ Thermal Throttling)
  void _startTempMonitor() {
    final interval = Duration(seconds: VideoConfig.TEMP_CHECK_SECONDS);
    
    _tempMonitorTimer = Timer.periodic(interval, (timer) async {
      if (!mounted) return;
      
      try {
        final tempFile = File('/sys/class/thermal/thermal_zone0/temp');
        if (await tempFile.exists()) {
          final temp = await tempFile.readAsString();
          final celsius = int.parse(temp.trim()) ~/ 1000;
          
          if (celsius >= VideoConfig.MAX_TEMP_CELSIUS) {
            if (VideoConfig.SHOW_DEBUG_LOGS) {
              print("🌡️ HIGH TEMP: ${celsius}°C! May throttle...");
            }
            
            // ลด Performance ชั่วคราว
            final native = _player?.platform as dynamic;
            if (native != null) {
              try {
                await native.setProperty('vd-lavc-threads', '2'); // ลด Thread
              } catch (e) {}
            }
          }
        }
      } catch (e) {
        // ไม่สามารถอ่านได้ (ปกติบางรุ่น)
      }
    });
  }

  void _startWatchdog() {
    _freezeWatchdog?.cancel();
    
    _freezeWatchdog = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (!mounted || _player == null) return;

      final state = _player!.state;
      
      if (state.playing) {
        
        if (state.buffering) {
          _bufferingCount++;
          if (_bufferingCount > 10) { // 20 วินาที
            if (VideoConfig.SHOW_DEBUG_LOGS) {
              print("⚠️ Buffering stuck (${_bufferingCount * 2}s)");
            }
            _bufferingCount = 0;
            _recreatePlayer(reason: "stuck-buffering");
            return;
          }
        } else {
          _bufferingCount = 0;
        }
        
        final currentPos = state.position;
        bool isTimeFrozen = !state.buffering && 
                            (currentPos - _lastPosition).abs().inMilliseconds < 100;

        bool isDimensionInvalid = (state.width == null || state.width == 0 || 
                                   state.height == null || state.height == 0);

        if (isTimeFrozen || isDimensionInvalid) {
          _freezeCount++;
          
          if (VideoConfig.SHOW_DEBUG_LOGS) {
            if (isDimensionInvalid) {
               print("⚠️ Freeze [${_freezeCount}x]: 0x0");
            } else {
               print("⚠️ Freeze [${_freezeCount}x]: ${currentPos.inSeconds}s");
            }
          }
        } else {
          if (_freezeCount > 0 && VideoConfig.SHOW_DEBUG_LOGS) {
            print("✅ Recovered!");
          }
          _freezeCount = 0;
          _lastPosition = currentPos;
        }

        if (_freezeCount >= 2) { // เพิ่มจาก 1 → 2 (ลด false positive)
          String cause = isDimensionInvalid ? "black-screen" : "time-freeze";
          if (VideoConfig.SHOW_DEBUG_LOGS) {
            print("🚨 $cause! Restarting...");
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

  void _startInitCheck() {
    _initCheckCount = 0;
    _initCheckTimer?.cancel();
    
    _initCheckTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _initCheckCount++;
      
      if (_ready) {
        if (VideoConfig.SHOW_DEBUG_LOGS) {
          print("✅ Ready in ${_initCheckCount}s");
        }
        timer.cancel();
        _initCheckCount = 0;
        return;
      }
      
      if (_initCheckCount >= 15) { // เพิ่มเป็น 15 วิ
        if (VideoConfig.SHOW_DEBUG_LOGS) {
          print("⏱️ Init timeout (15s)");
        }
        timer.cancel();
        _initCheckCount = 0;
        _recreatePlayer(reason: "init-timeout");
        return;
      }
      
      if (VideoConfig.SHOW_DEBUG_LOGS && _initCheckCount % 5 == 0) {
        print("⏳ Loading... (${_initCheckCount}s)");
      }
    });
  }

  Future<void> _recreatePlayer({required String reason}) async {
    if (VideoConfig.SHOW_DEBUG_LOGS) {
      print("🔄 Recreating: $reason");
    }
    
    _initCheckTimer?.cancel();
    _freezeWatchdog?.cancel();
    _completedSub?.cancel();
    _videoParamsSub?.cancel();

    _player?.dispose();
    _player = null;
    _controller = null;

    if (mounted) setState(() => _ready = false);

    await Future.delayed(const Duration(milliseconds: 200));
    if (!mounted) return;
    
    _playerStartTime = DateTime.now(); // Reset timer
    await _init();
    
    if (VideoConfig.ENABLE_WATCHDOG) {
      _startWatchdog();
    }
  }

  Future<void> _init() async {
    final bufferBytes = VideoConfig.BUFFER_SIZE_MB * 1024 * 1024;
    
    final p = Player(
      configuration: PlayerConfiguration(
        bufferSize: bufferBytes,
        logLevel: MPVLogLevel.error, // ลด Log Spam
      ),
    );
    _player = p;

    final native = p.platform as dynamic;
    if (native != null) {
      try {
        // hwdec
        try {
          await native.setProperty('hwdec', VideoConfig.HWDEC_MODE);
        } catch (e) {
          await native.setProperty('hwdec', 'no');
        }
        
        // Threads
        if (VideoConfig.HWDEC_MODE == 'no') {
          await native.setProperty('vd-lavc-threads', '4');
        } else {
          await native.setProperty('vd-lavc-threads', '2');
        }
        
        await native.setProperty('profile', 'fast');
        
        // 🔥 แก้ video-sync Bug
        await native.setProperty('video-sync', 'audio'); // กลับมาใช้ audio
        
        // Cache - เพิ่มสูงสุด
        await native.setProperty('cache', 'yes');
        await native.setProperty('cache-secs', '20'); // เพิ่มเป็น 20 วิ
        await native.setProperty('demuxer-max-bytes', '${VideoConfig.BUFFER_SIZE_MB * 2}M'); // ×2
        await native.setProperty('demuxer-readahead-secs', '10');
        
        // 🔥 แก้ File Corruption
        await native.setProperty('demuxer-lavf-o', 'fflags=+genpts+discardcorrupt+nobuffer');
        
        // 🔥 ลด GPU Memory
        await native.setProperty('vd-queue-max-samples', '2');
        await native.setProperty('vd-queue-max-bytes', '32M');
        
        // 🔥 Network (ถ้ามี)
        if (widget.url.startsWith('http')) {
          await native.setProperty('stream-buffer-size', '64M');
          await native.setProperty('cache-pause-initial', 'yes');
          await native.setProperty('cache-pause-wait', '3');
        }
        
        if (VideoConfig.SHOW_DEBUG_LOGS) {
          print("🎬 Init: hwdec=${VideoConfig.HWDEC_MODE}, buffer=${VideoConfig.BUFFER_SIZE_MB}MB");
        }
      } catch (e) {
        if (VideoConfig.SHOW_DEBUG_LOGS) {
          print("❌ Init failed: $e");
        }
      }
    }

    _controller = VideoController(
      p,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: VideoConfig.HWDEC_MODE != 'no',
        androidAttachSurfaceAfterVideoParameters: false,
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
          print("✅ ${params.w}x${params.h}");
        }
        if (mounted) setState(() {});
        widget.onReady?.call();
      }
    });

    _startInitCheck();

    final media = widget.file != null ? Media(widget.file!.path) : Media(widget.url);
    try {
      await p.open(media, play: true);
      await p.setVolume(100.0);
      await p.setPlaylistMode(widget.isLooping ? PlaylistMode.single : PlaylistMode.none);
    } catch (e) {
      if (VideoConfig.SHOW_DEBUG_LOGS) {
        print("❌ Video open failed: $e");
      }
      // รอแล้ว retry
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) {
        _recreatePlayer(reason: "open-failed");
      }
    }
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