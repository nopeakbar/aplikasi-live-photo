import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
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

  /// Menghasilkan video dengan color grading menggunakan LUT (HaldCLUT)
  static Future<File?> applyLUT(File inputVideo, String lutAssetPath) async {
    try {
      final dir = await getTemporaryDirectory();

      // 1. Ekstrak gambar LUT dari assets ke penyimpanan fisik sementara
      final lutFile = File('${dir.path}/temp_lut.png');
      final byteData = await rootBundle.load(lutAssetPath);
      await lutFile.writeAsBytes(
        byteData.buffer.asUint8List(
          byteData.offsetInBytes,
          byteData.lengthInBytes,
        ),
      );

      // 2. Siapkan path output video hasil grading
      final outputPath =
          '${dir.path}/graded_${DateTime.now().millisecondsSinceEpoch}.mp4';

      // 3. Command FFmpeg
      // [0:v] adalah video asli, [1:v] adalah gambar LUT
      final command =
          '-i "${inputVideo.path}" -i "${lutFile.path}" '
          '-filter_complex "[0:v][1:v]haldclut[v]" -map "[v]" '
          '-c:v libx264 -preset ultrafast '
          '-pix_fmt yuv420p ' // Memastikan pakai 8-bit warna standar
          '-profile:v baseline -level 3.0 ' // Membatasi profil agar enteng diputar
          '-movflags +faststart ' // Agar video bisa langsung diputar saat loading
          '"$outputPath"';

      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        // Hapus file LUT sementara biar gak menuhin memori
        if (await lutFile.exists()) {
          await lutFile.delete();
        }
        return File(outputPath);
      }
    } catch (e) {
      print("Error apply LUT: $e");
    }
    return null;
  }
}
