package com.nopeakbar.vetecam.camera

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CaptureRequest
import android.os.Build
import android.util.Log
import android.util.Range
import android.util.Size
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import com.nopeakbar.vetecam.MainActivity
import com.google.common.util.concurrent.ListenableFuture
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
    private var camera: Camera? = null

    // ── GPU Surface Processor untuk Live Filter ─────────────────────────────
    private var lutProcessor: LutSurfaceProcessor? = null
    @Volatile private var currentLutAsset: String? = null // null = Normal (tanpa filter)

    // ── Zoom state ──────────────────────────────────────────────────────────
    @Volatile private var currentZoomRatio: Float = 1.0f
    @Volatile private var isStabilizationEnabled: Boolean = true
    @Volatile private var currentDynamicZoom: Float = 1.0f

    // ── Physical Ultrawide State (Hybrid Logic) ─────────────────────────────
    private var physicalUwId: String? = null
    private var isUsingPhysicalUw = false

    private val cameraExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    private val preBuffer  = CircularBuffer(1500L)
    private val postBuffer = CircularBuffer(1500L)

    private var isCapturing = false
    private val POST_DURATION_MS = 1500L
    private var postCaptureStartMs = 0L

    @Volatile private var isPhotoSaved = false
    @Volatile private var isPostCaptureDone = false
    private var preFramesSnapshot: List<VideoFrame> = emptyList()

    private var activePhotoFile: File? = null
    private var activeVideoFile: File? = null

    private var lensFacing = CameraSelector.LENS_FACING_BACK
    private var flashMode = ImageCapture.FLASH_MODE_OFF

    @Volatile private var currentFps: Int = 30
    @Volatile private var currentRes: Int = 1080

    // ── Preview attachment ───────────────────────────────────────────────────

    fun debugPrintAllCameraInfo() {
        val camManager = activity.getSystemService(Context.CAMERA_SERVICE) as android.hardware.camera2.CameraManager
        try {
            Log.d("CameraDebug", "=== MULAI CEK KAMERA FISIK ===")
            for (id in camManager.cameraIdList) {
                val chars = camManager.getCameraCharacteristics(id)
                val facing = chars.get(CameraCharacteristics.LENS_FACING)
                val focalLengths = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                
                val facingStr = when (facing) {
                    CameraCharacteristics.LENS_FACING_BACK -> "BELAKANG"
                    CameraCharacteristics.LENS_FACING_FRONT -> "DEPAN"
                    else -> "LAINNYA"
                }
                
                Log.d("CameraDebug", "📸 ID: $id | Posisi: $facingStr | Focal Length: ${focalLengths?.contentToString()} mm")
            }
            Log.d("CameraDebug", "=== SELESAI CEK KAMERA FISIK ===")
        } catch (e: Exception) {
            Log.e("CameraDebug", "Error ngecek kamera", e)
        }
    }
    
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

    // ── Camera control ───────────────────────────────────────────────────────

    fun switchCamera() {
        lensFacing = if (lensFacing == CameraSelector.LENS_FACING_BACK)
            CameraSelector.LENS_FACING_FRONT else CameraSelector.LENS_FACING_BACK
        
        currentZoomRatio = 1.0f        
        isUsingPhysicalUw = false      
        
        startCamera(currentFps, currentRes)
    }

    fun setFlashMode(mode: Int) {
        flashMode = mode
        imageCapture?.flashMode = flashMode
    }

    fun setStabilizationMode(enabled: Boolean) {
        isStabilizationEnabled = enabled
        startCamera(currentFps, currentRes) 
    }

    // ── LIVE FILTER / GRADING ───────────────────────────────────────────────
    
    fun setLiveFilter(lutAsset: String?) {
        // Jika filter yang dipilih sama dengan yang sedang aktif, abaikan
        if (currentLutAsset == lutAsset) return
        
        currentLutAsset = lutAsset
        Log.d("CameraManager", "Live Filter diganti ke: ${lutAsset ?: "Normal"}")
        
        // Restart kamera agar UseCaseGroup di-rebuild dengan (atau tanpa) efek GPU
        startCamera(currentFps, currentRes)
    }

    // ── ULTRAWIDE: Zoom & Hardware Detection (HYBRID) ───────────────────────

    fun getUltrawideInfo(): Map<String, Any> {
        val cameraManager = activity.getSystemService(Context.CAMERA_SERVICE) as android.hardware.camera2.CameraManager
        val targetFacing = if (lensFacing == CameraSelector.LENS_FACING_BACK)
            CameraCharacteristics.LENS_FACING_BACK
        else
            CameraCharacteristics.LENS_FACING_FRONT

        physicalUwId = null

        try {
            for (id in cameraManager.cameraIdList) {
                val chars = cameraManager.getCameraCharacteristics(id)
                if (chars.get(CameraCharacteristics.LENS_FACING) != targetFacing) continue

                val focalLengths = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                if (focalLengths != null && focalLengths.isNotEmpty()) {
                    val minFocal = focalLengths.minOrNull() ?: Float.MAX_VALUE
                    if (minFocal < 2.5f) { 
                        physicalUwId = id
                        Log.d("CameraManager", "✅ Cek Fisik: Ketemu Ultrawide ID=$id (Focal: $minFocal mm)")
                        return mapOf("supported" to true, "minZoom" to 0.5)
                    }
                }
            }
        } catch (e: Exception) {
            Log.e("CameraManager", "Error saat cek fisik ultrawide", e)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val minZoom = getMinZoomRatio()
            val supported = minZoom < 1.0f
            if (supported) {
                Log.d("CameraManager", "✅ Cek Logis: Mendukung Ultrawide via Zoom Ratio (minZoom=$minZoom)")
                return mapOf("supported" to true, "minZoom" to minZoom.toDouble())
            }
        }

        Log.d("CameraManager", "❌ Ultrawide tidak didukung di device/posisi ini.")
        return mapOf("supported" to false, "minZoom" to 1.0)
    }

    fun setZoomRatio(requestedRatio: Float) {
        if (requestedRatio < 1.0f) {
            if (physicalUwId != null) {
                isUsingPhysicalUw = true
                currentZoomRatio = 1.0f 
                Log.d("CameraManager", "setZoomRatio: Pindah ke Lensa Fisik ID=$physicalUwId")
            } else {
                isUsingPhysicalUw = false
                currentZoomRatio = getMinZoomRatio()
                Log.d("CameraManager", "setZoomRatio: Pindah ke Logical Zoom (minZoom=$currentZoomRatio)")
            }
        } else {
            isUsingPhysicalUw = false
            currentZoomRatio = 1.0f
            Log.d("CameraManager", "setZoomRatio: Kembali ke lensa utama")
        }
        startCamera(currentFps, currentRes)
    }

    fun updateActiveZoom(ratio: Float) {
        // Jika menggunakan lensa fisik ultrawide, base ratio-nya adalah 1.0 untuk lensa tersebut
        val targetRatio = if (isUsingPhysicalUw) {
            maxOf(1.0f, ratio) 
        } else {
            maxOf(getMinZoomRatio(), ratio)
        }
        
        currentDynamicZoom = targetRatio
        camera?.cameraControl?.setZoomRatio(targetRatio)
    }

    private fun getMinZoomRatio(): Float {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return 1.0f

        val cameraManager = activity.getSystemService(Context.CAMERA_SERVICE)
                as android.hardware.camera2.CameraManager

        val targetFacing = if (lensFacing == CameraSelector.LENS_FACING_BACK)
            CameraCharacteristics.LENS_FACING_BACK
        else
            CameraCharacteristics.LENS_FACING_FRONT

        for (id in cameraManager.cameraIdList) {
            try {
                val chars = cameraManager.getCameraCharacteristics(id)
                if (chars.get(CameraCharacteristics.LENS_FACING) != targetFacing) continue

                val capabilities = chars.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES) ?: continue

                val isLogicalMultiCamera = capabilities.contains(
                    CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA
                )
                val isBackwardCompatible = capabilities.contains(
                    CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_BACKWARD_COMPATIBLE
                )
                if (!isBackwardCompatible && !isLogicalMultiCamera) continue

                val range = chars.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)
                val minZoom = range?.lower ?: 1.0f
                if (minZoom < 1.0f) {
                    return minZoom
                }
            } catch (e: Exception) {
                Log.w("CameraManager", "Error reading characteristics for camera $id", e)
            }
        }
        return 1.0f
    }

    // ── Start / restart camera session ────────────────────────────────────────

    fun startCamera(targetFps: Int = 30, targetRes: Int = 1080) { 
        currentFps = targetFps
        currentRes = targetRes
        val targetSize = when (targetRes) {
            720 -> Size(720, 1280)
            2160 -> Size(2160, 3840)
            else -> Size(1080, 1920) 
        }

        debugPrintAllCameraInfo()

        CameraHelper.getProvider(
            activity,
            ContextCompat.getMainExecutor(activity),
            object : CameraHelper.CameraProviderCallback {
                override fun onAvailable(cameraProvider: ProcessCameraProvider) {

                    // ── Preview ──────────────────────────────────────────────
                    val previewBuilder = Preview.Builder()
                    val previewInterop = Camera2Interop.Extender(previewBuilder)
                    previewInterop.setCaptureRequestOption(
                        CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
                        Range(targetFps, targetFps)
                    )

                    previewInterop.setCaptureRequestOption(
                        CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
                        if (isStabilizationEnabled) CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON
                        else CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF
                    )
                    
                    if (!isUsingPhysicalUw && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        previewInterop.setCaptureRequestOption(
                            CaptureRequest.CONTROL_ZOOM_RATIO,
                            currentZoomRatio
                        )
                    }

                    preview = previewBuilder.build().also { prev ->
                        previewView?.let { prev.setSurfaceProvider(it.surfaceProvider) }
                    }

                    // ── Still capture ────────────────────────────────────────
                    val imageCaptureBuilder = ImageCapture.Builder()
                        .setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY)
                        .setFlashMode(flashMode)

                    Camera2Interop.Extender(imageCaptureBuilder).setCaptureRequestOption(
                        CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE,
                        if (isStabilizationEnabled) CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_ON
                        else CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_OFF
                    )
                        
                    if (!isUsingPhysicalUw && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        Camera2Interop.Extender(imageCaptureBuilder)
                            .setCaptureRequestOption(
                                CaptureRequest.CONTROL_ZOOM_RATIO,
                                currentZoomRatio
                            )
                    }
                    imageCapture = imageCaptureBuilder.build()

                    // ── Frame analysis ───────────────────────────────────────
                    val analysisBuilder = ImageAnalysis.Builder()
                        .setTargetResolution(targetSize)
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
                        
                    val analysisInterop = Camera2Interop.Extender(analysisBuilder)
                    analysisInterop.setCaptureRequestOption(
                        CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
                        Range(targetFps, targetFps)
                    )

                    analysisInterop.setCaptureRequestOption(
                        CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
                        if (isStabilizationEnabled) CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_ON
                        else CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF
                    )
                    
                    if (!isUsingPhysicalUw && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        analysisInterop.setCaptureRequestOption(
                            CaptureRequest.CONTROL_ZOOM_RATIO,
                            currentZoomRatio
                        )
                    }

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

                    // ── PENYUSUNAN USE CASE GROUP & CAMERA EFFECT ────────────
                    try {
                        cameraProvider.unbindAll()

                        val selectorBuilder = CameraSelector.Builder().requireLensFacing(lensFacing)
                        if (isUsingPhysicalUw && physicalUwId != null) {
                            selectorBuilder.addCameraFilter(CameraFilter { cameraInfos ->
                                val filtered = cameraInfos.filter { info ->
                                    Camera2CameraInfo.from(info).cameraId == physicalUwId
                                }
                                if (filtered.isNotEmpty()) filtered else cameraInfos
                            })
                        }
                        val cameraSelector = selectorBuilder.build()

                        val useCaseGroupBuilder = UseCaseGroup.Builder()
                            .addUseCase(preview!!)
                            .addUseCase(imageCapture!!)
                            .addUseCase(imageAnalyzer!!)

                        // Jika filter LUT aktif, tambahkan efek GPU ke UseCaseGroup
                        if (currentLutAsset != null) {
                            if (lutProcessor == null) {
                                lutProcessor = LutSurfaceProcessor(activity)
                            }
                            lutProcessor?.setLutAsset(currentLutAsset)

                            // Terapkan efek HANYA ke PREVIEW saja (Hapus or CameraEffect.IMAGE_CAPTURE)
                            val lutEffect = object : CameraEffect(
                                CameraEffect.PREVIEW, // <--- UBAH DI SINI
                                Executors.newSingleThreadExecutor(),
                                lutProcessor!!,
                                androidx.core.util.Consumer { t -> Log.e("CameraManager", "GPU Effect Error", t) }
                            ) {}
                            
                            useCaseGroupBuilder.addEffect(lutEffect)
                            Log.d("CameraManager", "✅ CameraEffect ditambahkan dengan LUT: $currentLutAsset")
                        }

                        val useCaseGroup = useCaseGroupBuilder.build()

                        // Bind menggunakan UseCaseGroup, BUKAN use case individual
                        camera = cameraProvider.bindToLifecycle(
                            activity,
                            cameraSelector,
                            useCaseGroup 
                        )
                        Log.d("CameraManager", "✅ Camera started: fps=$targetFps, " +
                                "lens=$lensFacing, filter=$currentLutAsset")
                    } catch (e: Exception) {
                        Log.e("CameraManager", "bindToLifecycle failed", e)
                    }
                }

                override fun onError(e: Exception) {
                    Log.e("CameraManager", "Failed to get CameraProvider", e)
                }
            }
        )
    }

    // ── Motion photo capture ─────────────────────────────────────────────────

    fun takeMotionPhoto(isLiveEnabled: Boolean) {
        if (isCapturing) {
            Log.w("CameraManager", "Still capturing, ignoring request")
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
            isPostCaptureDone = true
        }

        isPhotoSaved = false
        postCaptureStartMs = System.currentTimeMillis()

        val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US)
            .format(System.currentTimeMillis())
        val appFolder = File(
            android.os.Environment.getExternalStoragePublicDirectory(
                android.os.Environment.DIRECTORY_PICTURES
            ),
            "Vetecam"
        ).also { if (!it.exists()) it.mkdirs() }

        val photoFile = File(appFolder, "IMG_${timestamp}_MP.jpg")
        val videoFile = File(appFolder, ".VID_${timestamp}_MP.mp4")

        activePhotoFile = photoFile
        activeVideoFile = videoFile

        imageCapture?.takePicture(
            ImageCapture.OutputFileOptions.Builder(photoFile).build(),
            ContextCompat.getMainExecutor(activity),
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                    Log.d("CameraManager", "Photo saved. isLiveEnabled=$isLiveEnabled")
                    isPhotoSaved = true
                    if (isLiveEnabled) {
                        checkAndEncode(photoFile, videoFile)
                    } else {
                        android.media.MediaScannerConnection.scanFile(
                            activity, arrayOf(photoFile.absolutePath), arrayOf("image/jpeg")
                        ) { path, _ -> Log.d("CameraManager", "Scanned: $path") }
                    }
                }
                override fun onError(e: ImageCaptureException) {
                    Log.e("CameraManager", "Photo capture failed", e)
                    isCapturing = false
                }
            }
        )
    }

    private fun checkAndEncode(photoFile: File, videoFile: File) {
        if (isPhotoSaved && isPostCaptureDone) {
            isPhotoSaved = false
            isPostCaptureDone = false

            val capturedFps = currentFps

            Thread {
                val postFrames = postBuffer.getBufferSnapshot()
                val allFrames  = preFramesSnapshot + postFrames

                if (allFrames.size > 1) {
                    val durMs = allFrames.last().timestampMs - allFrames.first().timestampMs
                    Log.d("CameraManager", "Encoding: ${allFrames.size} frames, " +
                            "duration=${durMs}ms, fps=$capturedFps")
                }

                try {
                    val presentationTimestampUs: Long = if (preFramesSnapshot.size >= 2) {
                        val preDurMs = preFramesSnapshot.last().timestampMs -
                                       preFramesSnapshot.first().timestampMs
                        maxOf(0L, preDurMs) * 1000L
                    } else {
                        1_500_000L
                    }

                    VideoEncoder().encodeToMp4(allFrames, videoFile, capturedFps)
                    MotionPhotoMuxer.mux(photoFile, videoFile, presentationTimestampUs)

                    android.media.MediaScannerConnection.scanFile(
                        activity,
                        arrayOf(photoFile.absolutePath),
                        null
                    ) { path, uri ->
                        Log.d("CameraManager", "✅ MediaStore scan done: $path | $uri")
                    }
                    Log.d("CameraManager", "✅ Motion Photo complete")
                } catch (e: Exception) {
                    Log.e("CameraManager", "Encode/mux error", e)
                }
            }.start()
        }
    }
}