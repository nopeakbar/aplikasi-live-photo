package com.example.motion_photo_app.camera

import android.util.Log
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream

object MotionPhotoMuxer {

    fun mux(photoFile: File, videoFile: File) {
        try {
            // KRITIS: Baca video SETELAH VideoEncoder selesai menulis file.
            // File.length() di sini sudah byte-perfect karena videoFile sudah closed oleh MediaMuxer.
            val videoBytes = videoFile.readBytes()
            val videoSize  = videoBytes.size

            if (videoSize == 0) {
                Log.e("MotionPhotoMuxer", "Video file kosong! Muxing dibatalkan.")
                return
            }

            // =========================================================
            // FIX #1: Namespace prefix WAJIB "GCamera:" bukan "Camera:"
            //         Samsung Gallery melakukan literal string-match pada
            //         "GCamera:MotionPhoto" — bukan resolusi yang URI namespace.
            //
            // FIX #2: Elemen dalam rdf:li WAJIB <Container:Item/>,
            //         bukan <rdf:Description/>.
            //         Atribut rdf:parseType="Resource" pada rdf:li WAJIB ada.
            //
            // FIX #3: Item:Padding="0" wajib disertakan sesuai spec
            //         Motion Photo format 1.0 (Android Developers).
            //
            // Referensi: Research PDF 1 halaman 5-6, dan
            //            https://developer.android.com/media/platform/motion-photo-format
            // =========================================================
            val xmpBody = """<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 5.1.0-jc003">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about=""
        xmlns:Container="http://ns.google.com/photos/1.0/container/"
        xmlns:Item="http://ns.google.com/photos/1.0/container/item/"
        xmlns:GCamera="http://ns.google.com/photos/1.0/camera/"
        GCamera:MotionPhoto="1"
        GCamera:MotionPhotoVersion="1"
        GCamera:MotionPhotoPresentationTimestampUs="1500000">
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

            // xpacket begin harus menyertakan UTF-8 BOM (\uFEFF) sesuai XMP spec ISO 16684-1
            val fullXmp = "<?xpacket begin=\"\uFEFF\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n$xmpBody\n<?xpacket end=\"w\"?>"

            // XMP namespace identifier diakhiri null byte \0 — wajib untuk APP1 segment
            val xmpNamespaceId = "http://ns.adobe.com/xap/1.0/\u0000"
            val xmpPayload     = xmpNamespaceId.toByteArray(Charsets.UTF_8) + fullXmp.toByteArray(Charsets.UTF_8)

            // APP1 segment: marker FF E1 + 2-byte length (termasuk 2 byte length itu sendiri)
            val segmentDataLength = xmpPayload.size + 2
            val app1Marker = byteArrayOf(
                0xFF.toByte(), 0xE1.toByte(),
                (segmentDataLength shr 8).toByte(),
                segmentDataLength.toByte()
            )
            val app1Segment = app1Marker + xmpPayload

            // Baca JPEG asli dan bersihkan XMP lama agar tidak terjadi duplikasi
            val originalPhotoBytes = photoFile.readBytes()
            val cleanPhotoBytes    = removeExistingXmp(originalPhotoBytes)

            // Tulis ke tempFile dulu — jangan overwrite langsung ke sumber yang sedang dibaca
            val tempFile = File(photoFile.parent, "TEMP_${photoFile.name}")

            FileOutputStream(tempFile).use { out ->
                // [1] SOI marker FF D8 dari cleanPhotoBytes
                out.write(cleanPhotoBytes, 0, 2)

                // [2] Inject APP1 XMP Motion Photo V1 baru
                out.write(app1Segment)

                // [3] Sisa JPEG (header EXIF orientation dll + image data), tanpa XMP lama
                out.write(cleanPhotoBytes, 2, cleanPhotoBytes.size - 2)

                // [4] Append MP4 langsung setelah FF D9 (EOI) JPEG — tight concatenation
                out.write(videoBytes)

                out.flush()
            }

            // Timpa file foto asli dengan file gabungan
            tempFile.copyTo(photoFile, overwrite = true)
            tempFile.delete()

            Log.d("MotionPhotoMuxer", "✅ Motion Photo V1 OK | " +
                    "GCamera:MotionPhoto=1 | Item:Length=$videoSize bytes | " +
                    "File: ${photoFile.name}")

        } catch (e: Exception) {
            Log.e("MotionPhotoMuxer", "Gagal muxing file: ${e.message}", e)
        }
    }

    /**
     * Membersihkan semua APP1 XMP dari file JPEG tanpa merusak segment lain
     * (EXIF orientasi, thumbnail, ICC profile, dll tetap dipertahankan).
     *
     * FIX #4: Ditambahkan bounds checking sebelum membaca segmentLength
     *         untuk mencegah ArrayIndexOutOfBoundsException pada JPEG corrupt.
     */
    private fun removeExistingXmp(photoBytes: ByteArray): ByteArray {
        val out = ByteArrayOutputStream(photoBytes.size)
        var i = 0

        // Validasi SOI (FF D8)
        if (photoBytes.size < 4 ||
            photoBytes[0] != 0xFF.toByte() ||
            photoBytes[1] != 0xD8.toByte()) {
            Log.w("MotionPhotoMuxer", "Bukan JPEG valid! Kembalikan file asli.")
            return photoBytes
        }

        out.write(photoBytes, 0, 2) // Tulis SOI
        i = 2

        while (i < photoBytes.size - 1) {

            // Setiap marker JPEG diawali byte 0xFF
            if (photoBytes[i] != 0xFF.toByte()) {
                // Struktur tidak terduga — tulis sisa dan selesai
                out.write(photoBytes, i, photoBytes.size - i)
                break
            }

            val marker = photoBytes[i + 1].toInt() and 0xFF

            // SOS (0xDA): mulai image data, tidak ada length field — tulis semua sisa
            if (marker == 0xDA) {
                out.write(photoBytes, i, photoBytes.size - i)
                break
            }

            // EOI (0xD9): akhir gambar — tulis marker dan berhenti
            if (marker == 0xD9) {
                out.write(photoBytes, i, 2)
                break
            }

            // Padding / stuffed byte — skip satu byte
            if (marker == 0x00 || marker == 0xFF) {
                out.write(photoBytes[i].toInt())
                i++
                continue
            }

            // FIX #4: Bounds check sebelum baca 2-byte segment length
            if (i + 3 >= photoBytes.size) {
                Log.w("MotionPhotoMuxer", "JPEG truncated di offset $i. Tulis sisa.")
                out.write(photoBytes, i, photoBytes.size - i)
                break
            }

            val segmentLength = ((photoBytes[i + 2].toInt() and 0xFF) shl 8) or
                                 (photoBytes[i + 3].toInt() and 0xFF)

            // Minimum valid: length field minimal bernilai 2
            if (segmentLength < 2) {
                Log.w("MotionPhotoMuxer", "Segment length tidak valid ($segmentLength). Tulis sisa.")
                out.write(photoBytes, i, photoBytes.size - i)
                break
            }

            var isXmpToRemove = false

            // Cek APP1 (0xE1) — bisa berisi EXIF atau XMP
            if (marker == 0xE1 && segmentLength > 4) {
                val headerStart = i + 4
                val headerEnd   = minOf(headerStart + 36, photoBytes.size)
                if (headerEnd > headerStart) {
                    val headerStr = String(photoBytes, headerStart, headerEnd - headerStart, Charsets.ISO_8859_1)
                    // XMP standard namespace — wajib dihapus agar tidak collision
                    if (headerStr.startsWith("http://ns.adobe.com/xap/1.0/")) {
                        isXmpToRemove = true
                        Log.d("MotionPhotoMuxer", "Hapus XMP APP1 lama (offset=$i, length=$segmentLength)")
                    }
                    // XMP Extended packet — juga hapus
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