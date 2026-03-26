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

  // ── Camera settings ──────────────────────────────────────────────────────
  int _targetFps = 30;
  bool _isLiveEnabled = true;
  int _flashMode = 2; // 0: Auto, 1: On, 2: Off

  // ── Ultrawide / zoom state ───────────────────────────────────────────────
  // _ultrawideSupported: set once at init from native hardware query.
  // _minZoomRatio: the actual min zoom of this device (0.5, 0.6, etc.).
  // _isUltrawide: whether the current session is in ultrawide mode.
  bool _ultrawideSupported = false;
  double _minZoomRatio = 0.5;
  bool _isUltrawide = false;

  // ── Other features ───────────────────────────────────────────────────────
  bool _showGrid = false;
  int _timerSetting = 0;
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
    setState(() => _statusText = 'Requesting permissions...');
    final camStatus = await Permission.camera.request();
    await Permission.storage.request();
    await Permission.manageExternalStorage.request();

    if (!camStatus.isGranted) {
      setState(() => _statusText = 'Camera permission denied');
      return;
    }

    await NativeBridge.startCameraPreview(fps: _targetFps);
    await NativeBridge.setFlashMode(_flashMode);

    // Query ultrawide support from native hardware AFTER camera starts.
    // This ensures CameraManager has the correct lensFacing set.
    final info = await NativeBridge.getUltrawideInfo();

    if (mounted) {
      setState(() {
        _cameraReady = true;
        _statusText = '';
        _ultrawideSupported = info.supported;
        _minZoomRatio = info.minZoom;
      });
    }
  }

  Future<void> _restartCamera() async {
    if (!mounted) return;
    setState(() {
      _cameraReady = false;
      _statusText = 'Restarting camera...';
    });
    await NativeBridge.startCameraPreview(fps: _targetFps);
    await NativeBridge.setFlashMode(_flashMode);

    // Re-query ultrawide info in case facing changed
    final info = await NativeBridge.getUltrawideInfo();

    if (mounted) {
      setState(() {
        _cameraReady = true;
        _statusText = '';
        _ultrawideSupported = info.supported;
        _minZoomRatio = info.minZoom;
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

  // ── FIXED: zoom toggle ────────────────────────────────────────────────────
  // FIX: The previous implementation changed _currentZoom state and called
  // NativeBridge.setZoomRatio() without any feedback loop. The user saw "0.5x"
  // in the UI but the camera never switched because:
  //   1. The native reflection call failed silently.
  //   2. There was no loading state — the user couldn't tell if the switch
  //      was in progress.
  //
  // NEW behavior:
  //   1. Toggle _isUltrawide flag.
  //   2. Show loading state (_cameraReady = false) while the session restarts.
  //   3. Call setZoomRatio() with the correct signal value:
  //        - 0.5 means "switch to ultrawide" (native maps this to actual minZoom)
  //        - 1.0 means "return to main lens"
  //   4. Wait for the session restart, then re-enable the preview.
  //
  // The brief "camera restarting" flash is intentional and expected — switching
  // to a different physical sensor requires a full session teardown + rebuild.
  void _toggleZoom() async {
    if (!_ultrawideSupported) return;
    HapticFeedback.selectionClick();

    final newIsUltrawide = !_isUltrawide;

    setState(() {
      _isUltrawide = newIsUltrawide;
      _cameraReady = false;
    });

    // Pass 0.5 as the "use ultrawide" signal, or 1.0 as "use main lens".
    // Native side reads CONTROL_ZOOM_RATIO_RANGE.lower from CameraCharacteristics
    // and uses the actual device min zoom — ignoring the exact value we pass.
    await NativeBridge.setZoomRatio(newIsUltrawide ? 0.5 : 1.0);

    // Give the camera session a moment to restart before re-enabling the preview.
    // startCamera() is asynchronous on the native side; we wait for it to settle.
    await Future.delayed(const Duration(milliseconds: 800));
    if (mounted) {
      setState(() => _cameraReady = true);
    }
  }

  Future<void> _flipCamera() async {
    HapticFeedback.lightImpact();
    setState(() {
      _cameraReady = false;
      _isUltrawide = false; // Reset zoom on camera flip
    });
    await NativeBridge.switchCamera();
    await Future.delayed(const Duration(milliseconds: 600));

    // Re-query ultrawide support for the new facing direction
    final info = await NativeBridge.getUltrawideInfo();
    if (mounted) {
      setState(() {
        _cameraReady = true;
        _ultrawideSupported = info.supported;
        _minZoomRatio = info.minZoom;
      });
    }
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
      _statusText = _isLiveEnabled ? 'Recording...' : '';
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

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Camera preview
          _cameraReady
              ? const AndroidView(
                  viewType: 'com.akbar.motionphoto/camera_preview',
                  creationParamsCodec: StandardMessageCodec(),
                )
              : _buildPlaceholder(),

          // 2. Grid overlay
          if (_showGrid) _buildGridOverlay(),

          // 3. Top bar
          Positioned(top: 0, left: 0, right: 0, child: _buildTopBar()),

          // 4. Status chip
          if (_statusText.isNotEmpty)
            Positioned(
              top: 100,
              left: 0,
              right: 0,
              child: Center(child: _buildStatusChip()),
            ),

          // 5. Countdown overlay
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

          // 6. Recording flash
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

          // 7. Zoom toggle button (only shown when ultrawide is supported)
          //
          // FIX: The button is now:
          //   - Hidden entirely when ultrawide is not supported on this device.
          //   - Shows the real zoom label from hardware (e.g. "0.6x" if minZoom=0.6).
          //   - Disabled during camera restart (opacity feedback).
          if (_cameraReady && _ultrawideSupported)
            Positioned(
              bottom: 140,
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
                      color: _isUltrawide
                          ? Colors.white.withOpacity(0.25)
                          : Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _isUltrawide ? Colors.white70 : Colors.white30,
                        width: 1,
                      ),
                    ),
                    child: Text(
                      // Show the real device min zoom label or "1x"
                      _isUltrawide
                          ? '${_minZoomRatio.toStringAsFixed(1)}x'
                          : '1x',
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

          // 8. Bottom controls
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
            _statusText.isEmpty ? 'Starting camera...' : _statusText,
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

              // Live toggle
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

              // FPS toggle
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
          // Gallery thumbnail
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

          // Shutter
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

          // Flip camera
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
