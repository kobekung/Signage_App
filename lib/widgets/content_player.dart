import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../models/layout_model.dart';
import '../services/preload_service.dart';

class ContentPlayer extends StatefulWidget {
  final SignageWidget widget;
  final VoidCallback? onFinished; // เรียกเมื่อเล่นจบ (สำหรับ Trigger Mode)
  final bool isTriggerMode;       // บอกว่าเป็นโหมดแทรกคิว
  final Function(bool isFullscreen)? onFullscreenChange; // บอกแม่ว่าตอนนี้ต้องเต็มจอไหม

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
    
    // แปลง Props ให้เป็น List เสมอ
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
        _currentIndex = 0; // วนลูปสำหรับโหมดปกติ
      }
    }

    final item = _playlist[_currentIndex];
    
    // แจ้งแม่เรื่อง Fullscreen
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

    // --- VIDEO (VLC) ---
    if (type == 'video') {
      final url = item['url'];
      File? cachedFile = await PreloadService.getCachedFile(url);
      
      bool shouldLoop = !widget.isTriggerMode && _playlist.length == 1;

      content = _VideoItem(
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
      child: _currentContent ?? const SizedBox(),
    );
  }
}

// --- Sub Widgets ---

// [UPDATED] VLC Video Item with "Deep Debugging" Info
class _VideoItem extends StatefulWidget {
  final File? file;
  final String url;
  final bool isLooping;
  final VoidCallback onFinished;

  const _VideoItem({
    super.key, 
    this.file, 
    required this.url, 
    required this.isLooping, 
    required this.onFinished
  });

  @override
  State<_VideoItem> createState() => _VideoItemState();
}

class _VideoItemState extends State<_VideoItem> {
  late VlcPlayerController _videoPlayerController;
  bool _isInitialized = false;
  String? _errorMessage;
  Timer? _timeoutTimer;
  
  // ตัวแปรสำหรับ Debug
  double _bufferPercent = 0.0;
  String _currentState = "Initializing...";
  int _retryCount = 0;

  @override
  void initState() {
    super.initState();
    _initVlcPlayer();
  }

  void _initVlcPlayer() {
    String path = widget.file != null ? widget.file!.path : widget.url;
    
    _videoPlayerController = VlcPlayerController.network(
      path, 
      hwAcc: HwAcc.disabled, // Software Decode (เสถียรสุดสำหรับ Android Box)
      autoPlay: true,
      options: VlcPlayerOptions(
        advanced: VlcAdvancedOptions([
          VlcAdvancedOptions.networkCaching(2000), // Buffer 2000ms (2 วิ)
        ]),
        video: VlcVideoOptions([
          VlcVideoOptions.dropLateFrames(true), 
        ]),
        // http: VlcHttpOptions([
        //   VlcHttpOptions.reconnect(true), // พยายามต่อใหม่ถ้าหลุด
        // ]),
      ),
    );

    _videoPlayerController.addListener(_onVideoStateChanged);

    // Timeout 30 วินาที (เผื่อเน็ตช้า)
    _timeoutTimer = Timer(const Duration(seconds: 30), () {
      if (mounted && !_isInitialized) {
        _showError("Timeout: 30s passed. Still not playing.\nBuffer: ${_bufferPercent.toStringAsFixed(1)}%");
      }
    });
  }

  void _onVideoStateChanged() async {
    if (!mounted) return;

    // 1. ดึงค่าสถานะปัจจุบันมาโชว์
    final state = _videoPlayerController.value.playingState;
    final buffer = _videoPlayerController.value.bufferPercent; // VLC ส่งค่า 0-100 มาให้

    setState(() {
      _currentState = state.toString().split('.').last; // เช่น Buffering, Playing
      _bufferPercent = buffer;
    });

    // 2. ถ้าเริ่มเล่นได้แล้ว (Playing)
    if (!_isInitialized && _videoPlayerController.value.isPlaying) {
      _timeoutTimer?.cancel();
      setState(() {
        _isInitialized = true;
      });
    }

    // 3. เช็คจบ
    if (_videoPlayerController.value.isEnded) {
      if (widget.isLooping) {
        await _videoPlayerController.seekTo(Duration.zero);
        await _videoPlayerController.play();
      } else {
        _cleanupAndFinish();
      }
    }

    // 4. เช็ค Error
    if (_videoPlayerController.value.hasError) {
      _timeoutTimer?.cancel();
      _showError("VLC Error: ${_videoPlayerController.value.errorDescription}");
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    print("❌ Video Error: $msg");
    setState(() {
      _errorMessage = msg;
    });

    // ค้างหน้า Error ไว้ 5 วิ แล้วข้าม
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted) _cleanupAndFinish();
    });
  }

  void _cleanupAndFinish() {
    _videoPlayerController.removeListener(_onVideoStateChanged);
    widget.onFinished();
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    try {
      _videoPlayerController.removeListener(_onVideoStateChanged);
      _videoPlayerController.stopRendererScanning();
      _videoPlayerController.dispose();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ------------------------------------
    // 1. กรณี Error
    // ------------------------------------
    if (_errorMessage != null) {
      return Container(
        color: Colors.black,
        width: double.infinity,
        height: double.infinity,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 60),
            const SizedBox(height: 20),
            Text(_errorMessage!, 
              textAlign: TextAlign.center, 
              style: const TextStyle(color: Colors.white, fontSize: 16)
            ),
            const SizedBox(height: 20),
            const LinearProgressIndicator(color: Colors.red),
            const SizedBox(height: 10),
            const Text("Skipping...", style: TextStyle(color: Colors.white54)),
          ],
        ),
      );
    }

    return Stack(
      alignment: Alignment.center,
      children: [
        // ------------------------------------
        // 2. Player
        // ------------------------------------
        VlcPlayer(
          controller: _videoPlayerController,
          aspectRatio: 16 / 9,
          placeholder: const Center(child: CircularProgressIndicator()),
        ),
        
        // ------------------------------------
        // 3. Loading & Debug Info (โชว์จนกว่าจะเริ่มเล่น)
        // ------------------------------------
        if (!_isInitialized)
          Container(
            color: Colors.black87, // ดำเข้มๆ ให้อ่านง่าย
            width: double.infinity,
            height: double.infinity,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CircularProgressIndicator(color: Colors.white),
                const SizedBox(height: 20),
                
                // --- ส่วนสำคัญ: ข้อมูล Debug ---
                Text(
                  "Status: $_currentState", // เช่น Buffering, Opening
                  style: const TextStyle(color: Colors.greenAccent, fontSize: 20, fontWeight: FontWeight.bold)
                ),
                const SizedBox(height: 10),
                
                // หลอด Buffer
                SizedBox(
                  width: 200,
                  child: LinearProgressIndicator(
                    value: _bufferPercent / 100, // แปลง 0-100 เป็น 0.0-1.0
                    backgroundColor: Colors.grey,
                    color: Colors.blue,
                    minHeight: 10,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  "Buffering: ${_bufferPercent.toStringAsFixed(1)}%",
                  style: const TextStyle(color: Colors.white, fontSize: 16)
                ),
                
                const SizedBox(height: 20),
                // โชว์ URL เผื่อพิมพ์ผิด (ตัดให้สั้นหน่อยจะได้ไม่รก)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    "Source: ...${widget.url.substring(widget.url.length > 30 ? widget.url.length - 30 : 0)}",
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ),
                
                const SizedBox(height: 30),
                OutlinedButton.icon(
                  onPressed: _cleanupAndFinish,
                  icon: const Icon(Icons.skip_next, color: Colors.white),
                  label: const Text("Force Skip", style: TextStyle(color: Colors.white)),
                  style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white54)),
                )
              ],
            ),
          ),
      ],
    );
  }
}

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