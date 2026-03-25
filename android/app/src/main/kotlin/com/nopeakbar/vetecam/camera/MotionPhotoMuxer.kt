package com.nopeakbar.vetecam.camera

import android.util.Log
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream

object MotionPhotoMuxer {

    // ── FIX #1: Terima presentationTimestampUs sebagai parameter ─────────────
    //
    // BUG ASLI: GCamera:MotionPhotoPresentationTimestampUs selalu hardcode 1500000.
    // Nilai ini merepresentasikan "pada detik ke-1.5 di dalam video, frame ini
    // cocok dengan foto statis". Ini hanya benar jika pre-buffer selalu penuh
    // 1500ms. Jika kamera baru dibuka (pre-buffer belum penuh), atau jika device
    // lambat mendeliver frame, nilai ini meleset — menyebabkan Google Photos /
    // Samsung Gallery menampilkan bingkai video yang salah sebagai thumbnail diam.
    //
    // CameraManager sekarang menghitung nilai ini secara dinamis dari timestamp
    // frame aktual dan mengoper ke sini.
    //
    // Default 1_500_000L (1.5 detik) dipertahankan sebagai fallback aman.
    fun mux(photoFile: File, videoFile: File, presentationTimestampUs: Long = 1_500_000L) {
        try {
            val videoBytes = videoFile.readBytes()
            val videoSize  = videoBytes.size

            if (videoSize == 0) {
                Log.e("MotionPhotoMuxer", "Video file kosong! Muxing dibatalkan.")
                return
            }

            // ── FIX #2: Clamp timestamp agar tidak negatif atau melebihi wajar ──
            // Nilai negatif akan membuat galeri menolak file, nilai terlalu besar
            // akan menyebabkan galeri mencari frame yang tidak ada.
            // Maksimum aman: 3000 detik (3_000_000_000 µs) = video 3 detik penuh.
            val safeTimestampUs = presentationTimestampUs.coerceIn(0L, 3_000_000_000L)

            Log.d("MotionPhotoMuxer", "Muxing: videoSize=$videoSize bytes, " +
                    "presentationTimestampUs=$safeTimestampUs µs " +
                    "(${safeTimestampUs / 1_000} ms)")

            val xmpBody = """<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 5.1.0-jc003">
    <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about=""
            xmlns:Container="http://ns.google.com/photos/1.0/container/"
            xmlns:Item="http://ns.google.com/photos/1.0/container/item/"
            xmlns:GCamera="http://ns.google.com/photos/1.0/camera/"
            GCamera:MotionPhoto="1"
            GCamera:MotionPhotoVersion="1"
            GCamera:MotionPhotoPresentationTimestampUs="$safeTimestampUs">
        <Container:Directory>
            <rdf:Seq>
            <rdf:li rdf:parseType="Resource">
                <Container:Item
                Item:Mime="image/jpeg"
                Item:Semantic="Primary"
                Item:Length="0"
                Item:Padding="0"/>
            </rdf:li>
            <rdf:li rdf:parseType="Resource">
                <Container:Item
                Item:Mime="video/mp4"
                Item:Semantic="MotionPhoto"
                Item:Length="$videoSize"
                Item:Padding="0"/>
            </rdf:li>
            </rdf:Seq>
        </Container:Directory>
        </rdf:Description>
    </rdf:RDF>
    </x:xmpmeta>"""

            val fullXmp = "<?xpacket begin=\"\uFEFF\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n$xmpBody\n<?xpacket end=\"w\"?>"

            val xmpNamespaceId = "http://ns.adobe.com/xap/1.0/\u0000"
            val xmpPayload     = xmpNamespaceId.toByteArray(Charsets.UTF_8) + fullXmp.toByteArray(Charsets.UTF_8)

            val segmentDataLength = xmpPayload.size + 2
            val app1Marker = byteArrayOf(
                0xFF.toByte(), 0xE1.toByte(),
                (segmentDataLength shr 8).toByte(),
                segmentDataLength.toByte()
            )
            val app1Segment = app1Marker + xmpPayload

            val originalPhotoBytes = photoFile.readBytes()
            val cleanPhotoBytes    = removeExistingXmp(originalPhotoBytes)

            val tempFile = File(photoFile.parent, "TEMP_${photoFile.name}")

            FileOutputStream(tempFile).use { out ->
                out.write(cleanPhotoBytes, 0, 2)
                out.write(app1Segment)
                out.write(cleanPhotoBytes, 2, cleanPhotoBytes.size - 2)
                out.write(videoBytes)
                out.flush()
            }

            tempFile.copyTo(photoFile, overwrite = true)
            tempFile.delete()

            Log.d("MotionPhotoMuxer", "✅ Motion Photo V1 OK | " +
                    "GCamera:MotionPhoto=1 | Item:Length=$videoSize bytes | " +
                    "PresentationTs=${safeTimestampUs}µs | File: ${photoFile.name}")

        } catch (e: Exception) {
            Log.e("MotionPhotoMuxer", "Gagal muxing file: ${e.message}", e)
        }
    }

    /**
     * Membersihkan semua APP1 XMP dari file JPEG tanpa merusak segment lain
     * (EXIF orientasi, thumbnail, ICC profile, dll tetap dipertahankan).
     */
    private fun removeExistingXmp(photoBytes: ByteArray): ByteArray {
        val out = ByteArrayOutputStream(photoBytes.size)
        var i = 0

        if (photoBytes.size < 4 ||
            photoBytes[0] != 0xFF.toByte() ||
            photoBytes[1] != 0xD8.toByte()) {
            Log.w("MotionPhotoMuxer", "Bukan JPEG valid! Kembalikan file asli.")
            return photoBytes
        }

        out.write(photoBytes, 0, 2)
        i = 2

        while (i < photoBytes.size - 1) {

            if (photoBytes[i] != 0xFF.toByte()) {
                out.write(photoBytes, i, photoBytes.size - i)
                break
            }

            val marker = photoBytes[i + 1].toInt() and 0xFF

            if (marker == 0xDA) {
                out.write(photoBytes, i, photoBytes.size - i)
                break
            }

            if (marker == 0xD9) {
                out.write(photoBytes, i, 2)
                break
            }

            if (marker == 0x00 || marker == 0xFF) {
                out.write(photoBytes[i].toInt())
                i++
                continue
            }

            if (i + 3 >= photoBytes.size) {
                Log.w("MotionPhotoMuxer", "JPEG truncated di offset $i. Tulis sisa.")
                out.write(photoBytes, i, photoBytes.size - i)
                break
            }

            val segmentLength = ((photoBytes[i + 2].toInt() and 0xFF) shl 8) or
                                (photoBytes[i + 3].toInt() and 0xFF)

            if (segmentLength < 2) {
                Log.w("MotionPhotoMuxer", "Segment length tidak valid ($segmentLength). Tulis sisa.")
                out.write(photoBytes, i, photoBytes.size - i)
                break
            }

            var isXmpToRemove = false

            if (marker == 0xE1 && segmentLength > 4) {
                val headerStart = i + 4
                val headerEnd   = minOf(headerStart + 36, photoBytes.size)
                if (headerEnd > headerStart) {
                    val headerStr = String(photoBytes, headerStart, headerEnd - headerStart, Charsets.ISO_8859_1)
                    if (headerStr.startsWith("http://ns.adobe.com/xap/1.0/")) {
                        isXmpToRemove = true
                        Log.d("MotionPhotoMuxer", "Hapus XMP APP1 lama (offset=$i, length=$segmentLength)")
                    }
                    if (headerStr.startsWith("http://ns.adobe.com/xmp/extension/")) {
                        isXmpToRemove = true
                        Log.d("MotionPhotoMuxer", "Hapus XMP Extended APP1 lama")
                    }
                }
            }

            if (!isXmpToRemove) {
                val segEnd = minOf(i + segmentLength + 2, photoBytes.size)
                out.write(photoBytes, i, segEnd - i)
            }

            i += segmentLength + 2
        }

        return out.toByteArray()
    }
}