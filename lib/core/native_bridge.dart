import 'package:flutter/services.dart';

class UltrawideInfo {
  final bool supported;
  final double minZoom;
  const UltrawideInfo({required this.supported, required this.minZoom});
}

class NativeBridge {
  static const MethodChannel _channel = MethodChannel(
    'com.akbar.motionphoto/camera',
  );

  static Future<void> captureMotionPhoto({required bool isLive}) async {
    try {
      print("Sending capture command to native...");
      final result = await _channel.invokeMethod('takeMotionPhoto', {
        'isLive': isLive,
      });
      print("Native result: $result");
    } on PlatformException catch (e) {
      print("Failed to capture photo: '${e.message}'.");
    }
  }

  static Future<void> setStabilizationMode(bool enabled) async {
    try {
      await _channel.invokeMethod('setStabilizationMode', {'enabled': enabled});
    } catch (e) {
      print("Failed to set stabilization: $e");
    }
  }

  static Future<void> startCameraPreview({
    int fps = 30,
    int resolution = 1080,
  }) async {
    try {
      await _channel.invokeMethod('startCamera', {
        'fps': fps,
        'resolution': resolution, // Tambahkan baris ini
      });
    } catch (e) {
      print("Failed to start camera: $e");
    }
  }

  static Future<void> switchCamera() async {
    try {
      await _channel.invokeMethod('switchCamera');
    } catch (e) {
      print("Failed to flip camera: $e");
    }
  }

  static Future<void> setLiveFilter(String? lutAssetPath) async {
    try {
      await _channel.invokeMethod('setLiveFilter', {'lutAsset': lutAssetPath});
    } catch (e) {
      print("Failed to set live filter: $e");
    }
  }

  static Future<void> setFlashMode(int mode) async {
    try {
      await _channel.invokeMethod('setFlashMode', {'mode': mode});
    } catch (e) {
      print("Failed to set flash: $e");
    }
  }

  // ── FIXED: setZoomRatio ────────────────────────────────────────────────────
  // Sends a zoom ratio signal to native.
  // Values < 1.0 tell native to activate the ultrawide lens.
  // Values >= 1.0 tell native to use the main lens.
  //
  // Native side no longer tries to set zoom on an existing session via reflection.
  // Instead, it restarts the camera session with CONTROL_ZOOM_RATIO baked into
  // the session builders via Camera2Interop. This is the approach recommended by
  // both Android developer documentation and the research analysis.
  static Future<void> setZoomRatio(double ratio) async {
    try {
      await _channel.invokeMethod('setZoomRatio', {'ratio': ratio});
    } catch (e) {
      print("Failed to set zoom: $e");
    }
  }

  static Future<void> updateActiveZoom(double ratio) async {
    try {
      await _channel.invokeMethod('updateActiveZoom', {'ratio': ratio});
    } catch (e) {
      print("Failed to update active zoom: $e");
    }
  }

  // ── NEW: getUltrawideInfo ──────────────────────────────────────────────────
  // Queries the native side for ultrawide support on this device.
  // Returns UltrawideInfo with:
  //   supported — true if CONTROL_ZOOM_RATIO_RANGE.lower < 1.0
  //   minZoom   — the actual minimum zoom ratio (e.g. 0.5 or 0.6)
  //
  // Call this once on camera screen init to decide whether to show the
  // zoom toggle button and what label to display.
  static Future<UltrawideInfo> getUltrawideInfo() async {
    try {
      final result = await _channel.invokeMethod<Map>('getUltrawideInfo');
      if (result != null) {
        final supported = result['supported'] as bool? ?? false;
        final minZoom = (result['minZoom'] as num?)?.toDouble() ?? 1.0;
        return UltrawideInfo(supported: supported, minZoom: minZoom);
      }
    } catch (e) {
      print("Failed to get ultrawide info: $e");
    }
    return const UltrawideInfo(supported: false, minZoom: 1.0);
  }
}
