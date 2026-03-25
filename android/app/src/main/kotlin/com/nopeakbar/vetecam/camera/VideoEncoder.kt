package com.nopeakbar.vetecam.camera

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.util.Log
import java.io.File

class VideoEncoder {

    fun encodeToMp4(frames: List<VideoFrame>, outputFile: File) {
        if (frames.isEmpty()) {
            Log.e("VideoEncoder", "Tidak ada frame!")
            return
        }

        val width         = frames[0].width
        val height        = frames[0].height
        val alignedWidth  = alignTo16(width)
        val alignedHeight = alignTo16(height)

        val totalDurationMs = frames.last().timestampMs - frames.first().timestampMs
        Log.d("VideoEncoder", "Encode ${frames.size} frame, durasi=${totalDurationMs}ms")

        var encoder: MediaCodec? = null
        var muxer: MediaMuxer? = null
        var trackIndex = -1
        var isMuxerStarted = false

        try {
            val format = MediaFormat.createVideoFormat(
                MediaFormat.MIMETYPE_VIDEO_AVC,
                alignedWidth,
                alignedHeight
            )
            format.setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar
            )
            format.setInteger(MediaFormat.KEY_BIT_RATE, 12_000_000)  // 12Mbps
            format.setInteger(MediaFormat.KEY_FRAME_RATE, 60)         // ✅ hardcode 60 sebagai hint
            format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)

            // ✅ API 29+ check — tidak crash di Android < 10
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                format.setFloat(MediaFormat.KEY_MAX_FPS_TO_ENCODER, 60f)
            }

            encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
            encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            encoder.start()

            muxer = MediaMuxer(outputFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            muxer.setOrientationHint(90)

            val bufferInfo = MediaCodec.BufferInfo()
            val baseTs = frames[0].timestampMs

            for (i in frames.indices) {
                val frame  = frames[i]
                val isLast = (i == frames.size - 1)

                // ✅ PTS dari hardware timestamp — akurat, reflect timing nyata
                val ptsUs = (frame.timestampMs - baseTs) * 1000L

                val paddedData = padFrameIfNeeded(
                    frame.data, frame.width, frame.height,
                    alignedWidth, alignedHeight
                )

                val inIdx = encoder.dequeueInputBuffer(10_000L)
                if (inIdx >= 0) {
                    val inputBuffer = encoder.getInputBuffer(inIdx)!!
                    inputBuffer.clear()
                    inputBuffer.put(paddedData, 0, minOf(paddedData.size, inputBuffer.remaining()))
                    encoder.queueInputBuffer(
                        inIdx,
                        0,
                        minOf(paddedData.size, inputBuffer.capacity()),
                        ptsUs,
                        if (isLast) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0
                    )
                }

                val r = drainEncoder(encoder, muxer, bufferInfo, trackIndex, isMuxerStarted, false)
                trackIndex = r.first
                isMuxerStarted = r.second
            }

            // Final drain sampai EOS
            var eos = false
            var timeout = 0
            while (!eos && timeout < 300) {
                val r = drainEncoder(encoder, muxer, bufferInfo, trackIndex, isMuxerStarted, true)
                trackIndex = r.first
                isMuxerStarted = r.second
                if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                    eos = true
                } else {
                    timeout++
                    Thread.sleep(5)
                }
            }

            Log.d("VideoEncoder", "✅ Done! ${frames.size} frame, ${totalDurationMs}ms")

        } catch (e: Exception) {
            Log.e("VideoEncoder", "Error encoding", e)
            outputFile.delete()
        } finally {
            try { encoder?.stop(); encoder?.release() } catch (e: Exception) { }
            try {
                if (isMuxerStarted) { muxer?.stop(); muxer?.release() }
            } catch (e: Exception) { }
        }
    }

    private fun drainEncoder(
        encoder: MediaCodec,
        muxer: MediaMuxer,
        bufferInfo: MediaCodec.BufferInfo,
        currentTrack: Int,
        currentMuxerStarted: Boolean,
        blocking: Boolean
    ): Pair<Int, Boolean> {
        var track = currentTrack
        var muxerStarted = currentMuxerStarted

        while (true) {
            val outIdx = encoder.dequeueOutputBuffer(
                bufferInfo,
                if (blocking) 10_000L else 0L
            )
            when {
                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    if (!muxerStarted) {
                        track = muxer.addTrack(encoder.outputFormat)
                        muxer.start()
                        muxerStarted = true
                    }
                }
                outIdx >= 0 -> {
                    val buf     = encoder.getOutputBuffer(outIdx)
                    val isConfig = bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (!isConfig && bufferInfo.size > 0 && muxerStarted && buf != null) {
                        buf.position(bufferInfo.offset)
                        buf.limit(bufferInfo.offset + bufferInfo.size)
                        muxer.writeSampleData(track, buf, bufferInfo)
                    }
                    encoder.releaseOutputBuffer(outIdx, false)
                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                }
                else -> break
            }
        }
        return Pair(track, muxerStarted)
    }

    private fun padFrameIfNeeded(
        src: ByteArray,
        srcW: Int, srcH: Int,
        dstW: Int, dstH: Int
    ): ByteArray {
        if (srcW == dstW && srcH == dstH) return src
        val dst = ByteArray(dstW * dstH * 3 / 2)
        for (row in 0 until srcH) {
            System.arraycopy(src, row * srcW, dst, row * dstW, srcW)
        }
        val srcUvOffset = srcW * srcH
        val dstUvOffset = dstW * dstH
        for (row in 0 until srcH / 2) {
            System.arraycopy(src, srcUvOffset + row * srcW, dst, dstUvOffset + row * dstW, srcW)
        }
        return dst
    }

    private fun alignTo16(value: Int): Int = (value + 15) and 15.inv()
}