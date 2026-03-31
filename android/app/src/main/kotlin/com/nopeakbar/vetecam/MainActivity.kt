package com.nopeakbar.vetecam

import androidx.annotation.NonNull
import com.nopeakbar.vetecam.camera.CameraManager
import com.nopeakbar.vetecam.camera.CameraPreviewFactory
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.FlutterInjector

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
                    val resolution = call.argument<Int>("resolution") ?: 1080 
                    cameraManager.startCamera(fps, resolution) 
                    result.success("Camera started at $fps FPS & ${resolution}p")
                }

                "takeMotionPhoto" -> {
                    val isLive = call.argument<Boolean>("isLive") ?: true
                    cameraManager.takeMotionPhoto(isLive)
                    result.success("Motion photo triggered")
                }

                "switchCamera" -> {
                    cameraManager.switchCamera()
                    result.success("Camera flipped")
                }

                "setFlashMode" -> {
                    val mode = call.argument<Int>("mode") ?: 0
                    cameraManager.setFlashMode(mode)
                    result.success("Flash mode set to $mode")
                }
                
                "setLiveFilter" -> {
                    val lutAssetName = call.argument<String>("lutAsset")
                    
                    // Terjemahkan path Flutter ("assets/luts/...") ke path Native Android ("flutter_assets/assets/luts/...")
                    val nativeAssetPath = if (lutAssetName != null) {
                        FlutterInjector.instance().flutterLoader().getLookupKeyForAsset(lutAssetName)
                    } else {
                        null
                    }
                    
                    cameraManager.setLiveFilter(nativeAssetPath) 
                    result.success("Filter changed to $lutAssetName")
                }

                "setStabilizationMode" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    cameraManager.setStabilizationMode(enabled)
                    result.success("Stabilization set to $enabled")
                }

                // ── Ultrawide zoom ──────────────────────────────────────────
                // FIX: This handler now calls the corrected setZoomRatio() which:
                //   1. Reads min zoom from CameraCharacteristics (not LiveData).
                //   2. Updates currentZoomRatio.
                //   3. Calls startCamera() to restart the session with
                //      CONTROL_ZOOM_RATIO baked into every use-case builder
                //      via Camera2Interop.
                "setZoomRatio" -> {
                    val ratio = call.argument<Double>("ratio")?.toFloat() ?: 1.0f
                    cameraManager.setZoomRatio(ratio)
                    result.success("Zoom ratio set to $ratio")
                }

                "updateActiveZoom" -> {
                    val ratio = call.argument<Double>("ratio")?.toFloat() ?: 1.0f
                    cameraManager.updateActiveZoom(ratio)
                    result.success("Active zoom updated to $ratio")
                }

                
                // ── NEW: Query ultrawide support before showing the button ──
                // Returns { "supported": Boolean, "minZoom": Double }
                // Flutter uses this to show/hide the 0.5x button and to know
                // the actual label to display (e.g. "0.6x" instead of "0.5x").
                "getUltrawideInfo" -> {
                    val info = cameraManager.getUltrawideInfo()
                    result.success(info)
                }

                else -> result.notImplemented()
            }
        }
    }
}