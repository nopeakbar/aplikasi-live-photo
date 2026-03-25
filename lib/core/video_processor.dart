import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:path_provider/path_provider.dart';

class VideoProcessor {
  /// Menghasilkan efek Bounce (Maju-Mundur / Boomerang)
  static Future<File?> generateBounce(File inputVideo) async {
    try {
      final dir = await getTemporaryDirectory();
      final outputPath =
          '${dir.path}/bounce_${DateTime.now().millisecondsSinceEpoch}.mp4';

      // Command FFmpeg:
      // 1. [0:v]reverse[r] -> Copy video dan jalankan mundur (reverse), simpan di variabel [r]
      // 2. [0:v][r]concat=n=2:v=1[v] -> Gabungkan video asli dengan video mundur
      final command =
          '-i "${inputVideo.path}" -filter_complex "[0:v]reverse[r];[0:v][r]concat=n=2:v=1[v]" -map "[v]" -c:v libx264 -preset ultrafast "$outputPath"';

      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        return File(outputPath);
      }
    } catch (e) {
      print("Error generate Bounce: $e");
    }
    return null;
  }

  /// Menghasilkan efek Long Exposure (Menggabungkan semua frame jadi 1 gambar)
  static Future<File?> generateLongExposure(File inputVideo) async {
    try {
      final dir = await getTemporaryDirectory();
      final outputPath =
          '${dir.path}/long_exp_${DateTime.now().millisecondsSinceEpoch}.jpg';

      // Command FFmpeg:
      // tmix=frames=60 -> Mencampur (blend) hingga 60 frame secara bersamaan untuk efek motion blur / long exposure
      // -vframes 1 -> Ambil 1 frame saja sebagai hasil akhir (JPEG)
      final command =
          '-i "${inputVideo.path}" -vf "tmix=frames=60:weights=\'1\'" -vframes 1 "$outputPath"';

      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        return File(outputPath);
      }
    } catch (e) {
      print("Error generate Long Exposure: $e");
    }
    return null;
  }
}
