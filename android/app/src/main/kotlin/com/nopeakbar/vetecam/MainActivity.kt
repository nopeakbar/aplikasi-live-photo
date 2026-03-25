package com.nopeakbar.vetecam

import androidx.annotation.NonNull
import com.nopeakbar.vetecam.camera.CameraManager
import com.nopeakbar.vetecam.camera.CameraPreviewFactory
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.akbar.motionphoto/camera" 
    private lateinit var cameraManager: CameraManager

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        cameraManager = CameraManager(this)

        flutterEngine.platformViewsController.registry.registerViewFactory(
            "com.akbar.motionphoto/camera_preview",
            CameraPreviewFactory(cameraManager)
        )

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startCamera" -> {
                    val fps = call.argument<Int>("fps") ?: 30
                    cameraManager.startCamera(fps)
                    result.success("Kamera dimulai dengan $fps FPS")
                }
                "takeMotionPhoto" -> {
                    val isLive = call.argument<Boolean>("isLive") ?: true
                    cameraManager.takeMotionPhoto(isLive)
                    result.success("Trigger Motion Photo berjalan!")
                }
                "switchCamera" -> {
                    cameraManager.switchCamera()
                    result.success("Kamera di-flip")
                }
                "setFlashMode" -> {
                    val mode = call.argument<Int>("mode") ?: 0
                    cameraManager.setFlashMode(mode)
                    result.success("Flash diubah ke $mode")
                }
                // ── TAMBAHAN UNTUK ULTRAWIDE ──
                "setZoomRatio" -> {
                    val ratio = call.argument<Double>("ratio")?.toFloat() ?: 1.0f
                    cameraManager.setZoomRatio(ratio)
                    result.success("Zoom diatur ke $ratio")
                }
                else -> result.notImplemented()
            }
        }
    }
}