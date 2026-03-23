package com.example.motion_photo_app.camera

import android.hardware.camera2.CaptureRequest
import android.util.Log
import android.util.Range
import android.util.Size
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import com.example.motion_photo_app.MainActivity
import java.io.File
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class CameraManager(private val activity: MainActivity) {

    private var imageCapture: ImageCapture? = null
    private var imageAnalyzer: ImageAnalysis? = null
    private var preview: Preview? = null
    private var previewView: PreviewView? = null

    private val cameraExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    // Buffer berbasis waktu (1500ms)
    private val preBuffer  = CircularBuffer(1500L)
    private val postBuffer = CircularBuffer(1500L)

    private var isCapturing = false
    private val POST_DURATION_MS = 1500L
    private var postCaptureStartMs = 0L

    // State pencegah Race Condition
    @Volatile private var isPhotoSaved = false
    @Volatile private var isPostCaptureDone = false
    private var preFramesSnapshot: List<VideoFrame> = emptyList()
    
    // Penampung file sementara
    private var activePhotoFile: File? = null
    private var activeVideoFile: File? = null

    // State Kamera Baru (Lens & Flash)
    private var lensFacing = CameraSelector.LENS_FACING_BACK
    private var flashMode = ImageCapture.FLASH_MODE_AUTO

    fun attachPreviewView(pv: PreviewView) {
        previewView = pv
        preview?.setSurfaceProvider(pv.surfaceProvider)
        Log.d("CameraManager", "PreviewView attached")
    }

    fun detachPreviewView() {
        preview?.setSurfaceProvider(null)
        previewView = null
        Log.d("CameraManager", "PreviewView detached")
    }

    fun switchCamera() {
        lensFacing = if (lensFacing == CameraSelector.LENS_FACING_BACK) {
            CameraSelector.LENS_FACING_FRONT
        } else {
            CameraSelector.LENS_FACING_BACK
        }
        startCamera(30) // Fallback default fps saat flip
    }

    fun setFlashMode(mode: Int) {
        flashMode = mode
        imageCapture?.flashMode = flashMode
    }

    fun startCamera(targetFps: Int = 30) {
        CameraHelper.getProvider(
            activity,
            ContextCompat.getMainExecutor(activity),
            object : CameraHelper.CameraProviderCallback {
                override fun onAvailable(cameraProvider: ProcessCameraProvider) {

                    preview = Preview.Builder().build().also { prev ->
                        previewView?.let { prev.setSurfaceProvider(it.surfaceProvider) }
                    }

                    imageCapture = ImageCapture.Builder()
                        .setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY)
                        .setFlashMode(flashMode)
                        .build()

                    val analysisBuilder = ImageAnalysis.Builder()
                        .setTargetResolution(Size(720, 1280))
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)

                    Camera2Interop.Extender(analysisBuilder)
                        .setCaptureRequestOption(
                            CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
                            Range(targetFps, targetFps)
                        )

                    val analyzer = analysisBuilder.build()

                    analyzer.setAnalyzer(cameraExecutor, ImageAnalysis.Analyzer { imageProxy ->
                        if (!isCapturing) {
                            preBuffer.addFrame(imageProxy)
                        } else {
                            postBuffer.addFrame(imageProxy)
                            val elapsed = System.currentTimeMillis() - postCaptureStartMs
                            if (elapsed >= POST_DURATION_MS) {
                                isCapturing = false
                                isPostCaptureDone = true
                                if (activePhotoFile != null && activeVideoFile != null) {
                                    checkAndEncode(activePhotoFile!!, activeVideoFile!!)
                                }
                            }
                        }
                    })

                    imageAnalyzer = analyzer

                    try {
                        cameraProvider.unbindAll()
                        cameraProvider.bindToLifecycle(
                            activity,
                            CameraSelector.Builder().requireLensFacing(lensFacing).build(),
                            preview,          
                            imageCapture,
                            imageAnalyzer
                        )
                        Log.d("CameraManager", "✅ Kamera $targetFps FPS + Preview siap! Lens: $lensFacing")
                    } catch (e: Exception) {
                        Log.e("CameraManager", "Gagal bindToLifecycle", e)
                    }
                }

                override fun onError(e: Exception) {
                    Log.e("CameraManager", "Gagal dapat CameraProvider", e)
                }
            }
        )
    }

    fun takeMotionPhoto(isLiveEnabled: Boolean) {
        if (isCapturing) {
            Log.w("CameraManager", "Masih capturing...")
            return
        }

        preFramesSnapshot = preBuffer.getBufferSnapshot()
        preBuffer.clear()
        postBuffer.clear()
        
        if (isLiveEnabled) {
            isCapturing = true
            isPostCaptureDone = false
        } else {
            isCapturing = false 
            isPostCaptureDone = true // Bypass video
        }
        
        isPhotoSaved = false
        postCaptureStartMs = System.currentTimeMillis()

        val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(System.currentTimeMillis())
        val appFolder = File(
            android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_PICTURES), 
            "MotionPhotoApp"
        ).also { if (!it.exists()) it.mkdirs() }

        val photoFile = File(appFolder, "IMG_$timestamp.jpg")
        
        // ✅ FIX: Tambahkan awalan titik agar menjadi hidden file untuk Flutter
        val videoFile = File(appFolder, ".VID_$timestamp.mp4")

        activePhotoFile = photoFile
        activeVideoFile = videoFile

        imageCapture?.takePicture(
            ImageCapture.OutputFileOptions.Builder(photoFile).build(),
            ContextCompat.getMainExecutor(activity),
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                    Log.d("CameraManager", "Foto OK. isLiveEnabled: $isLiveEnabled")
                    isPhotoSaved = true
                    
                    if (isLiveEnabled) {
                        checkAndEncode(photoFile, videoFile)
                    } else {
                        // Jika bukan Live Photo, scan fotonya saja
                        android.media.MediaScannerConnection.scanFile(
                            activity, arrayOf(photoFile.absolutePath), arrayOf("image/jpeg")
                        ) { path, _ -> Log.d("CameraManager", "Scanned Image Only: $path") }
                    }
                }
                override fun onError(e: ImageCaptureException) {
                    Log.e("CameraManager", "Foto gagal", e)
                    isCapturing = false
                }
            }
        )
    }

    private fun checkAndEncode(photoFile: File, videoFile: File) {
        if (isPhotoSaved && isPostCaptureDone) {
            isPhotoSaved = false
            isPostCaptureDone = false

            Thread {
                val postFrames = postBuffer.getBufferSnapshot()
                val allFrames  = preFramesSnapshot + postFrames

                if (allFrames.size > 1) {
                    val durMs = allFrames.last().timestampMs - allFrames.first().timestampMs
                    Log.d("CameraManager", "Mulai Encode: Total ${allFrames.size} frame, durasi=${durMs}ms")
                }

                try {
                    // 1. Encode video ke hidden file .mp4
                    VideoEncoder().encodeToMp4(allFrames, videoFile)
                    
                    // 2. Muxing: Menyatukan MP4 ke dalam file JPG dengan XMP Metadata V2
                    MotionPhotoMuxer.mux(photoFile, videoFile)

                    // 3. FIX Bug #3: Scan HANYA dilakukan SETELAH muxing selesai dan video terhapus.
                    android.media.MediaScannerConnection.scanFile(
                        activity,
                        arrayOf(photoFile.absolutePath),
                        arrayOf("image/jpeg")
                    ) { path, _ -> Log.d("CameraManager", "Scanned JPG Successfully: $path") }
                    
                    Log.d("CameraManager", "✅ Native Motion Photo selesai & Siap dibaca Galeri Samsung/Google Photos!")

                } catch (e: Exception) {
                    Log.e("CameraManager", "Error encode/muxing", e)
                }
            }.start()
        }
    }
}