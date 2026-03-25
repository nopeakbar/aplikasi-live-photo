import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../core/native_bridge.dart';
import 'gallery_screen.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with TickerProviderStateMixin {
  bool _cameraReady = false;
  bool _isCapturing = false;
  String _statusText = '';
  File? _lastPhoto;

  // ── State Pengaturan Kamera ──
  int _targetFps = 30;
  bool _isLiveEnabled = true;
  int _flashMode = 2; // 0: Auto, 1: On, 2: Off

  // ── TAMBAHAN UNTUK ULTRAWIDE ──
  double _currentZoom = 1.0;

  // ── State Fitur Baru ──
  bool _showGrid = false;
  int _timerSetting = 0; // 0: Off, 3: 3 detik, 10: 10 detik
  int _currentCountdown = 0;

  late AnimationController _shutterAnim;
  late Animation<double> _shutterScale;

  late AnimationController _liveAnim;
  late Animation<double> _liveOpacity;

  @override
  void initState() {
    super.initState();

    _shutterAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );

    _shutterScale = Tween<double>(
      begin: 1.0,
      end: 0.88,
    ).animate(CurvedAnimation(parent: _shutterAnim, curve: Curves.easeOut));

    _liveAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _liveOpacity = Tween<double>(begin: 0.4, end: 1.0).animate(_liveAnim);

    WidgetsBinding.instance.addPostFrameCallback((_) => _startKamera());
    _loadLastPhoto();
  }

  @override
  void dispose() {
    _shutterAnim.dispose();
    _liveAnim.dispose();
    super.dispose();
  }

  Future<void> _loadLastPhoto() async {
    final dir = Directory('/storage/emulated/0/Pictures/Vetecam');
    if (!await dir.exists()) return;
    final jpgs =
        dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.jpg'))
            .toList()
          ..sort(
            (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
          );
    if (jpgs.isNotEmpty) setState(() => _lastPhoto = jpgs.first);
  }

  Future<void> _startKamera() async {
    setState(() => _statusText = 'Meminta izin...');
    final camStatus = await Permission.camera.request();
    await Permission.storage.request();
    await Permission.manageExternalStorage.request();

    if (camStatus.isGranted) {
      await NativeBridge.startCameraPreview(fps: _targetFps);
      await NativeBridge.setFlashMode(_flashMode);
      setState(() {
        _cameraReady = true;
        _statusText = '';
      });
    } else {
      setState(() => _statusText = 'Izin kamera ditolak');
    }
  }

  Future<void> _restartCamera() async {
    if (!mounted) return;
    setState(() {
      _cameraReady = false;
      _statusText = 'Memulai ulang kamera...';
    });
    await NativeBridge.startCameraPreview(fps: _targetFps);
    await NativeBridge.setFlashMode(_flashMode);

    if (mounted) {
      setState(() {
        _cameraReady = true;
        _statusText = '';
      });
    }
  }

  void _toggleFps() {
    HapticFeedback.selectionClick();
    setState(() {
      _targetFps = _targetFps == 30 ? 60 : 30;
      _cameraReady = false;
    });
    _restartCamera();
  }

  void _toggleFlash() {
    HapticFeedback.selectionClick();
    setState(() => _flashMode = (_flashMode + 1) % 3);
    NativeBridge.setFlashMode(_flashMode);
  }

  void _toggleGrid() {
    HapticFeedback.selectionClick();
    setState(() => _showGrid = !_showGrid);
  }

  void _toggleTimer() {
    HapticFeedback.selectionClick();
    setState(() {
      if (_timerSetting == 0) {
        _timerSetting = 3;
      } else if (_timerSetting == 3) {
        _timerSetting = 10;
      } else {
        _timerSetting = 0;
      }
    });
  }

  // ── TAMBAHAN UNTUK ULTRAWIDE ──
  void _toggleZoom() {
    HapticFeedback.selectionClick();
    setState(() {
      _currentZoom = _currentZoom == 1.0 ? 0.5 : 1.0;
    });
    NativeBridge.setZoomRatio(_currentZoom);
  }

  Future<void> _flipCamera() async {
    HapticFeedback.lightImpact();
    setState(() {
      _cameraReady = false;
      _currentZoom = 1.0; // Reset zoom ke 1.0 setiap flip kamera
    });
    await NativeBridge.switchCamera();
    await Future.delayed(const Duration(milliseconds: 600));
    if (mounted) setState(() => _cameraReady = true);
  }

  Future<void> _jepret() async {
    if (_isCapturing || !_cameraReady || _currentCountdown > 0) return;

    if (_timerSetting > 0) {
      _mulaiHitungMundur();
      return;
    }

    await _eksekusiJepret();
  }

  void _mulaiHitungMundur() {
    setState(() => _currentCountdown = _timerSetting);
    Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_currentCountdown == 1) {
        timer.cancel();
        setState(() => _currentCountdown = 0);
        _eksekusiJepret();
      } else {
        HapticFeedback.lightImpact();
        setState(() => _currentCountdown--);
      }
    });
  }

  Future<void> _eksekusiJepret() async {
    HapticFeedback.mediumImpact();
    _shutterAnim.forward().then((_) => _shutterAnim.reverse());

    setState(() {
      _isCapturing = _isLiveEnabled;
      _statusText = _isLiveEnabled ? 'Merekam...' : '';
    });

    await NativeBridge.captureMotionPhoto(isLive: _isLiveEnabled);

    await Future.delayed(Duration(milliseconds: _isLiveEnabled ? 3000 : 500));
    await _loadLastPhoto();

    if (mounted) {
      setState(() {
        _isCapturing = false;
        _statusText = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Preview Kamera
          _cameraReady
              ? const AndroidView(
                  viewType: 'com.akbar.motionphoto/camera_preview',
                  creationParamsCodec: StandardMessageCodec(),
                )
              : _buildPlaceholder(),

          // 2. Grid Overlay (Garis 3x3)
          if (_showGrid) _buildGridOverlay(),

          // 3. Top Bar Menu
          Positioned(top: 0, left: 0, right: 0, child: _buildTopBar()),

          // 4. Status Chip (Merekam / Izin)
          if (_statusText.isNotEmpty)
            Positioned(
              top: 100,
              left: 0,
              right: 0,
              child: Center(child: _buildStatusChip()),
            ),

          // 5. Angka Timer Raksasa Tengah Layar
          if (_currentCountdown > 0)
            Center(
              child: Text(
                '$_currentCountdown',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 120,
                  fontWeight: FontWeight.w200,
                  shadows: [Shadow(color: Colors.black45, blurRadius: 10)],
                ),
              ),
            ),

          // 6. Flash Putih saat Jepret
          if (_isCapturing && _isLiveEnabled)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _isCapturing ? 0.06 : 0.0,
                  duration: const Duration(milliseconds: 300),
                  child: Container(color: Colors.white),
                ),
              ),
            ),

          // ── 7. TAMBAHAN: Tombol Zoom (1x / 0.5x) ──
          if (_cameraReady)
            Positioned(
              bottom: 140, // Berada pas di atas bottom bar
              left: 0,
              right: 0,
              child: Center(
                child: GestureDetector(
                  onTap: _toggleZoom,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.white30, width: 1),
                    ),
                    child: Text(
                      _currentZoom == 1.0 ? '1x' : '0.5x',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // 8. Bottom Controls
          Positioned(bottom: 0, left: 0, right: 0, child: _buildBottomBar()),
        ],
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: const Color(0xFF0A0A0A),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.camera_alt_outlined,
            color: Color(0xFF2A2A2A),
            size: 64,
          ),
          const SizedBox(height: 16),
          Text(
            _statusText.isEmpty ? 'Memulai kamera...' : _statusText,
            style: const TextStyle(
              color: Color(0xFF555555),
              fontSize: 13,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGridOverlay() {
    return IgnorePointer(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Expanded(child: _buildGridRow()),
          const Divider(height: 1, color: Colors.white30, thickness: 0.5),
          Expanded(child: _buildGridRow()),
          const Divider(height: 1, color: Colors.white30, thickness: 0.5),
          Expanded(child: _buildGridRow()),
        ],
      ),
    );
  }

  Widget _buildGridRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        Expanded(child: Container()),
        const VerticalDivider(width: 1, color: Colors.white30, thickness: 0.5),
        Expanded(child: Container()),
        const VerticalDivider(width: 1, color: Colors.white30, thickness: 0.5),
        Expanded(child: Container()),
      ],
    );
  }

  Widget _buildTopBar() {
    IconData flashIcon = Icons.flash_auto;
    if (_flashMode == 1) flashIcon = Icons.flash_on;
    if (_flashMode == 2) flashIcon = Icons.flash_off;

    return Container(
      padding: EdgeInsets.only(
        top: MediaQuery.of(context).padding.top + 8,
        left: 12,
        right: 12,
        bottom: 24,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xEE000000), Color(0x88000000), Colors.transparent],
        ),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: Icon(
                  flashIcon,
                  color: _flashMode == 1 ? Colors.yellow : Colors.white,
                  size: 22,
                ),
                onPressed: _toggleFlash,
              ),

              IconButton(
                icon: Icon(
                  _timerSetting == 0
                      ? Icons.timer_off_outlined
                      : _timerSetting == 3
                      ? Icons.timer_3_outlined
                      : Icons.timer_10_outlined,
                  color: _timerSetting > 0 ? Colors.yellow : Colors.white,
                  size: 22,
                ),
                onPressed: _toggleTimer,
              ),

              // Live Toggle Button
              GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _isLiveEnabled = !_isLiveEnabled);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: _isLiveEnabled
                        ? const Color(0xFFFF3B30)
                        : Colors.white24,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _isLiveEnabled
                            ? Icons.motion_photos_on
                            : Icons.motion_photos_paused,
                        color: Colors.white,
                        size: 14,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _isLiveEnabled ? 'LIVE' : 'OFF',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              IconButton(
                icon: Icon(
                  _showGrid ? Icons.grid_on : Icons.grid_off,
                  color: _showGrid ? Colors.yellow : Colors.white,
                  size: 22,
                ),
                onPressed: _toggleGrid,
              ),

              // FPS Toggle Button
              GestureDetector(
                onTap: _toggleFps,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _targetFps == 60 ? Colors.yellow : Colors.white54,
                    ),
                    borderRadius: BorderRadius.circular(8),
                    color: _targetFps == 60
                        ? Colors.yellow.withOpacity(0.15)
                        : Colors.white12,
                  ),
                  child: Text(
                    '${_targetFps}fps',
                    style: TextStyle(
                      color: _targetFps == 60 ? Colors.yellow : Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isCapturing) ...[
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFFFF3B30),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Text(
            _statusText,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 32,
        top: 32,
        left: 40,
        right: 40,
      ),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xEE000000), Colors.transparent],
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // ── Kiri: Thumbnail Galeri ──
          GestureDetector(
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const GalleryScreen()),
              );
              _loadLastPhoto();
            },
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white30, width: 1.5),
                color: Colors.white12,
              ),
              child: _lastPhoto != null
                  ? ClipOval(child: Image.file(_lastPhoto!, fit: BoxFit.cover))
                  : const Icon(
                      Icons.photo_library_outlined,
                      color: Colors.white70,
                      size: 20,
                    ),
            ),
          ),

          // ── Tengah: Tombol Shutter ──
          GestureDetector(
            onTap: _jepret,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white54, width: 4),
                  ),
                ),
                ScaleTransition(
                  scale: _shutterScale,
                  child: Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isCapturing
                          ? const Color(0xFFFF3B30)
                          : Colors.white,
                    ),
                    child: _isCapturing
                        ? const Icon(
                            Icons.stop_rounded,
                            color: Colors.white,
                            size: 28,
                          )
                        : null,
                  ),
                ),
              ],
            ),
          ),

          // ── Kanan: Tombol Flip Kamera ──
          GestureDetector(
            onTap: _flipCamera,
            child: Container(
              width: 48,
              height: 48,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white12,
              ),
              child: const Icon(
                Icons.flip_camera_ios_outlined,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
