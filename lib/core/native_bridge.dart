import 'package:flutter/services.dart';

class NativeBridge {
  static const MethodChannel _channel = MethodChannel(
    'com.akbar.motionphoto/camera',
  );

  static Future<void> captureMotionPhoto({required bool isLive}) async {
    try {
      print("Mengirim perintah ke Native untuk mengambil Motion Photo...");
      final result = await _channel.invokeMethod('takeMotionPhoto', {
        'isLive': isLive,
      });
      print("Hasil dari Native: $result");
    } on PlatformException catch (e) {
      print("Gagal mengambil foto: '${e.message}'.");
    }
  }

  static Future<void> startCameraPreview({int fps = 30}) async {
    try {
      await _channel.invokeMethod('startCamera', {'fps': fps});
    } catch (e) {
      print("Gagal memulai kamera: $e");
    }
  }

  static Future<void> switchCamera() async {
    try {
      await _channel.invokeMethod('switchCamera');
    } catch (e) {
      print("Gagal flip kamera: $e");
    }
  }

  static Future<void> setFlashMode(int mode) async {
    try {
      await _channel.invokeMethod('setFlashMode', {'mode': mode});
    } catch (e) {
      print("Gagal set flash: $e");
    }
  }
}
