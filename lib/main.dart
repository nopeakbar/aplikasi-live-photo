import 'package:flutter/material.dart';
import 'presentation/splash_screen.dart'; // Import file splash screen baru

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MotionPhotoApp());
}

class MotionPhotoApp extends StatelessWidget {
  const MotionPhotoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vetecam', // Ubah title menjadi nama aplikasimu
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      debugShowCheckedModeBanner:
          false, // Menghilangkan tulisan "DEBUG" di pojok kanan atas
      home:
          const SplashScreen(), // Ubah home agar memuat SplashScreen lebih dulu
    );
  }
}
