package com.example.motion_photo_app.camera

import android.util.Log
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream

object MotionPhotoMuxer {

    fun mux(photoFile: File, videoFile: File) {
        try {
            val videoBytes = videoFile.readBytes()
            val videoSize = videoBytes.size

            // FIX Bug #1 & #2: Gunakan Skema Motion Photo V2 (Container/Item) dan Item:Length
            val xmpString = """<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 5.1.0-jc003">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about=""
        xmlns:Container="http://ns.google.com/photos/1.0/container/"
        xmlns:Item="http://ns.google.com/photos/1.0/container/item/"
        xmlns:GCamera="http://ns.google.com/photos/1.0/camera/">
      <GCamera:MicroVideo>1</GCamera:MicroVideo>
      <GCamera:MicroVideoVersion>1</GCamera:MicroVideoVersion>
      <GCamera:MicroVideoPresentationTimestampUs>1500000</GCamera:MicroVideoPresentationTimestampUs>
      <Container:Directory>
        <rdf:Seq>
          <rdf:li>
            <rdf:Description Item:Mime="image/jpeg" Item:Semantic="Primary" Item:Length="0"/>
          </rdf:li>
          <rdf:li>
            <rdf:Description Item:Mime="video/mp4" Item:Semantic="MotionPhoto" Item:Length="$videoSize"/>
          </rdf:li>
        </rdf:Seq>
      </Container:Directory>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>"""

            val fullXmp = "<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n$xmpString\n<?xpacket end=\"w\"?>"
            
            // XMP Header untuk APP1 Segment JPEG
            val xmpHeader = "http://ns.adobe.com/xap/1.0/\u0000"
            val xmpPayload = xmpHeader.toByteArray() + fullXmp.toByteArray()

            // Marker APP1 (FF E1)
            val length = xmpPayload.size + 2
            val marker = byteArrayOf(0xFF.toByte(), 0xE1.toByte(), (length shr 8).toByte(), length.toByte())
            val app1Segment = marker + xmpPayload

            // 2. Baca file JPG asli
            val photoBytes = photoFile.readBytes()
            
            // FIX Bug #4: Buang segmen XMP APP1 bawaan dari JPG agar tidak terjadi tabrakan metadata
            val cleanPhotoBytes = removeExistingXmp(photoBytes)

            // 3. Gabungkan semuanya ke Temporary File
            val tempFile = File(photoFile.parent, "TEMP_${photoFile.name}")
            FileOutputStream(tempFile).use { out ->
                // Tulis SOI (Start of Image) FF D8 menggunakan byte JPG yang sudah bersih
                out.write(cleanPhotoBytes, 0, 2)
                
                // Suntikkan Metadata XMP V2 Baru
                out.write(app1Segment)
                
                // Tulis sisa gambar JPG
                out.write(cleanPhotoBytes, 2, cleanPhotoBytes.size - 2)
                
                // Tempelkan video MP4 di ujung paling bawah
                out.write(videoBytes)
            }

            // 4. Timpa file asli dengan file yang sudah digabung
            tempFile.copyTo(photoFile, overwrite = true)
            tempFile.delete()

            // ✅ FIX: Comment fungsi delete video sementara agar Flutter video_player bisa membaca hidden file-nya
            /*
            if (videoFile.exists()) {
                videoFile.delete()
            }
            */

            Log.d("MotionPhotoMuxer", "✅ XMP V2 Injected! Video size: $videoSize bytes")

        } catch (e: Exception) {
            Log.e("MotionPhotoMuxer", "Gagal muxing file", e)
        }
    }

    /**
     * Parse struktur biner JPEG dan hapus blok APP1 yang berisi XMP lama.
     */
    private fun removeExistingXmp(photoBytes: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        var i = 0
        
        // Verifikasi format JPEG (FF D8)
        if (photoBytes.size > 2 && photoBytes[0] == 0xFF.toByte() && photoBytes[1] == 0xD8.toByte()) {
            out.write(photoBytes, 0, 2)
            i = 2
        } else {
            return photoBytes // Kembalikan file asli jika bukan JPEG valid
        }

        while (i < photoBytes.size - 1) {
            if (photoBytes[i] == 0xFF.toByte()) {
                val marker = photoBytes[i + 1].toInt() and 0xFF
                
                // Jika sudah sampai SOS (Start of Scan), data gambar sesungguhnya dimulai
                if (marker == 0xDA) { 
                    out.write(photoBytes, i, photoBytes.size - i)
                    break
                }
               
                val segmentLength = ((photoBytes[i + 2].toInt() and 0xFF) shl 8) or (photoBytes[i + 3].toInt() and 0xFF)
                var isXmp = false
                
                // Cek jika segmen adalah APP1 (E1)
                if (marker == 0xE1 && segmentLength >= 29) {
                    val headerBytes = photoBytes.copyOfRange(i + 4, minOf(i + 33, photoBytes.size))
                    val headerStr = String(headerBytes)
                    // Jika memiliki namespace Adobe XAP, berarti itu blok XMP lama
                    if (headerStr.startsWith("http://ns.adobe.com/xap/1.0/")) {
                        isXmp = true
                        Log.d("MotionPhotoMuxer", "Menghapus APP1 XMP lama...")
                    }
                }
                
                // Jika blok BUKAN XMP lama (misal EXIF orientasi, dll), pertahankan (tulis kembali)
                if (!isXmp) {
                    out.write(photoBytes, i, segmentLength + 2)
                }
                
                i += segmentLength + 2
            } else {
                break // Pengaman untuk struktur rusak
            }
        }
        return out.toByteArray()
    }
}