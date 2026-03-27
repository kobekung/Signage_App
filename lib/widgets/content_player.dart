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
  final VoidCallback? onCycleComplete;
  final bool isTriggerMode;
  final Function(bool isFullscreen)? onFullscreenChange;

  const ContentPlayer({
    super.key,
    required this.widget,
    this.onFinished,
    this.onCycleComplete,
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
        widget.onCycleComplete?.call();
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

      if (!mounted || token != _playToken) return;

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
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: Colors.black,
      child: _currentContent ?? const Center(
        child: SizedBox(
          width: 20, height: 20,
          child: CircularProgressIndicator(color: Colors.white30, strokeWidth: 2),
        ),
      ),
    );
  }
}

// ==========================================
// 🌐 WebView Host (Keep Alive + Recover Only When Network Error)
// ==========================================
class _WebviewHost extends StatefulWidget {
  final String url;
  const _WebviewHost({super.key, required this.url});

  @override
  State<_WebviewHost> createState() => _WebviewHostState();
}

class _WebviewHostState extends State<_WebviewHost> {
  WebViewController? _controller;
  StreamSubscription? _netSubscription;
  Timer? _retryTimer;

  // ✅ reload เฉพาะตอน “เคยพังเพราะเน็ต”
  bool _needRecover = false;

  @override
  void initState() {
    super.initState();
    _initWebView();
    _listenToNetwork();
    _startRetryTimer();
  }

  void _startRetryTimer() {
    _retryTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (!_needRecover || !mounted) return;
      final hasInternet = await _hasRealInternet();
      if (!mounted || !hasInternet) return;
      setState(() => _needRecover = false);
      _controller?.loadRequest(Uri.parse(widget.url));
    });
  }

  void _initWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (_needRecover && mounted) setState(() => _needRecover = false);
          },
          onWebResourceError: (error) {
            final desc = error.description.toLowerCase();

            final isNetworkError =
                desc.contains("net::err_internet_disconnected") ||
                desc.contains("net::err_name_not_resolved") ||
                desc.contains("net::err_address_unreachable") ||
                desc.contains("net::err_connection_timed_out") ||
                desc.contains("net::err_connection_closed");

            if (isNetworkError && !_needRecover && mounted) {
              setState(() => _needRecover = true);
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));

    setState(() {});
  }

  void _listenToNetwork() {
    _netSubscription =
        Connectivity().onConnectivityChanged.listen((results) async {
      final hasConnection = results.any((r) => r != ConnectivityResult.none);
      if (!hasConnection) return;

      // ✅ ถ้าไม่เคยพังเพราะเน็ต ห้าม reload
      if (!_needRecover) return;

      final hasInternet = await _hasRealInternet();
      if (!mounted || !hasInternet) return;

      if (mounted) setState(() => _needRecover = false);
      _controller?.loadRequest(Uri.parse(widget.url));
    });
  }

  Future<bool> _hasRealInternet() async {
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
      _needRecover = false;
      _controller?.loadRequest(Uri.parse(widget.url));
    }
  }

  @override
  void dispose() {
    _netSubscription?.cancel();
    _retryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c == null) return const ColoredBox(color: Colors.black);
    return Stack(
      children: [
        WebViewWidget(controller: c),
        if (_needRecover)
          Container(
            color: Colors.black,
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Colors.white),
                  SizedBox(height: 16),
                  Text(
                    'Waiting for connection...',
                    style: TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ==========================================
// 🎥 Video Player (Android TV Safe Mode + onReady)
// ==========================================
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

class _DisposableVideoPlayerState extends State<_DisposableVideoPlayer>
    with WidgetsBindingObserver {
  Player? _player;
  VideoController? _controller;
  bool _ready = false;

  Timer? _stuckWatchdog;
  Timer? _positionWatchdog;
  StreamSubscription? _completedSub;
  StreamSubscription? _videoParamsSub;
  StreamSubscription? _errorSub;

  Duration? _lastWatchdogPos;
  int _positionStuckCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    _stuckWatchdog?.cancel();
    _positionWatchdog?.cancel();
    _completedSub?.cancel();
    _videoParamsSub?.cancel();
    _errorSub?.cancel();

    _player?.dispose();
    _player = null;
    _controller = null;

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (!mounted || _ready) return; // ✅ กำลังเล่นอยู่ปกติ ไม่ recreate
        _recreatePlayer(reason: "resume");
      });
    }
  }

  Future<void> _recreatePlayer({required String reason}) async {
    _stuckWatchdog?.cancel();
    _positionWatchdog?.cancel();
    _completedSub?.cancel();
    _videoParamsSub?.cancel();
    _errorSub?.cancel();

    _player?.dispose();
    _player = null;
    _controller = null;

    if (mounted) setState(() => _ready = false);

    await Future.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
    await _init();
  }

  void _startPositionWatchdog() {
    _positionWatchdog?.cancel();
    _lastWatchdogPos = null;
    _positionStuckCount = 0;

    _positionWatchdog = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!mounted) return;
      final p = _player;
      if (p == null) { _positionWatchdog?.cancel(); return; }
      if (p.state.completed) { _positionWatchdog?.cancel(); return; }

      final pos = p.state.position;
      if (pos == _lastWatchdogPos) {
        _positionStuckCount++;
        if (_positionStuckCount >= 2) { // ค้าง 16+ วินาที
          _positionWatchdog?.cancel();
          _recreatePlayer(reason: "position-stuck");
        }
      } else {
        _positionStuckCount = 0;
        _lastWatchdogPos = pos;
      }
    });
  }

  Future<void> _init() async {
    final p = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 4 * 1024 * 1024,
        logLevel: MPVLogLevel.warn,
      ),
    );
    _player = p;

    final native = p.platform as dynamic;
    if (native != null) {
      try {
        await native.setProperty('hwdec', 'no'); // สำคัญมาก (กันจอดำ)
        await native.setProperty('hwdec-codecs', 'all');
        await native.setProperty('profile', 'fast');
        await native.setProperty('video-sync', 'audio');
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
        // เพิ่งพร้อม
        _ready = true;
        if (mounted) setState(() {});
        _startPositionWatchdog();
      } else if (_ready && (params.w == null || params.h == null)) {
        // surface หลุดหลังจาก ready แล้ว (จอดำแต่ position ยังขยับ)
        _recreatePlayer(reason: "surface-lost");
      }
    });

    _errorSub = p.stream.error.listen((error) {
      if (mounted && error.isNotEmpty) {
        _recreatePlayer(reason: "error");
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
