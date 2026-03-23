package com.example.motion_photo_app.camera

import androidx.camera.core.ImageProxy
import android.util.Log
import java.util.LinkedList

data class VideoFrame(
    val data: ByteArray,
    val width: Int,
    val height: Int,
    val timestampMs: Long
)

class CircularBuffer(private val maxDurationMs: Long = 1500L) {

    private val frameQueue = LinkedList<VideoFrame>()

    var actualWidth: Int = 0
        private set
    var actualHeight: Int = 0
        private set

    private var frameCount = 0
    private var firstFrameTimeMs = 0L

    @Synchronized
    fun addFrame(image: ImageProxy) {
        try {
            val w = image.width
            val h = image.height

            // Hardware timestamp — akurat dari sensor, tidak ada jitter
            val nowMs = image.imageInfo.timestamp / 1_000_000L

            if (actualWidth == 0) {
                actualWidth = w
                actualHeight = h
                firstFrameTimeMs = nowMs
                Log.d("CircularBuffer", "Dimensi aktual: ${w}x${h}")
            }

            frameCount++
            if (frameCount % 30 == 0) {
                val elapsed = (nowMs - firstFrameTimeMs) / 1000.0
                if (elapsed > 0) {
                    val fps = frameCount / elapsed
                    Log.d("CircularBuffer", "FPS aktual: %.1f fps (%d frame dalam %.1fs)"
                        .format(fps, frameCount, elapsed))
                }
            }

            val data = extractNv12Bytes(image, w, h)
            frameQueue.add(VideoFrame(data, w, h, nowMs))

            // Time-based buffer: Hapus frame yang umurnya > 1500ms
            val cutoffTime = nowMs - maxDurationMs
            while (frameQueue.isNotEmpty() && frameQueue.first().timestampMs < cutoffTime) {
                frameQueue.removeFirst()
            }

        } catch (e: Exception) {
            Log.e("CircularBuffer", "Gagal memproses frame", e)
        } finally {
            image.close()
        }
    }

    @Synchronized
    fun getBufferSnapshot(): List<VideoFrame> {
        val frames = frameQueue.toList()
        if (frames.isNotEmpty()) {
            val durationMs = frames.last().timestampMs - frames.first().timestampMs
            Log.d("CircularBuffer", "Snapshot: ${frames.size} frame, durasi = ${durationMs}ms")
        }
        return frames
    }

    @Synchronized
    fun clear() {
        frameQueue.clear()
    }

    private fun extractNv12Bytes(image: ImageProxy, width: Int, height: Int): ByteArray {
        val nv12 = ByteArray(width * height * 3 / 2)

        val yPlane  = image.planes[0]
        val uPlane  = image.planes[1]
        val vPlane  = image.planes[2]

        val yBuffer = yPlane.buffer
        val uBuffer = uPlane.buffer
        val vBuffer = vPlane.buffer

        val yRowStride    = yPlane.rowStride
        val uvRowStride   = uPlane.rowStride
        val uvPixelStride = uPlane.pixelStride

        // ── Y Plane: bulk copy per baris ──────────────────────────────────
        var pos = 0
        for (row in 0 until height) {
            yBuffer.position(row * yRowStride)
            val toCopy = minOf(width, yBuffer.remaining())
            if (toCopy > 0) {
                yBuffer.get(nv12, pos, toCopy)
            }
            pos += width
        }

        // ── UV Plane ──────────────────────────────────────────────────────
        if (uvPixelStride == 2) {
            // Semi-planar NV12/NV21
            for (row in 0 until height / 2) {
                uBuffer.position(row * uvRowStride)
                val toCopy = minOf(width, uBuffer.remaining())
                if (toCopy > 0) {
                    uBuffer.get(nv12, pos, toCopy)
                    pos += toCopy
                }
            }
        } else {
            // Planar fallback
            for (row in 0 until height / 2) {
                for (col in 0 until width / 2) {
                    uBuffer.position(row * uvRowStride + col)
                    nv12[pos++] = uBuffer.get()
                    vBuffer.position(row * vPlane.rowStride + col)
                    nv12[pos++] = vBuffer.get()
                }
            }
        }

        return nv12
    }
}