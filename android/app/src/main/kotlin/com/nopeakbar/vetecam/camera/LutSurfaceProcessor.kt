package com.nopeakbar.vetecam.camera

import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLUtils
import android.opengl.Matrix
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import androidx.camera.core.SurfaceOutput
import androidx.camera.core.SurfaceProcessor
import androidx.camera.core.SurfaceRequest
import androidx.core.content.ContextCompat
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

class LutSurfaceProcessor(private val context: Context) : SurfaceProcessor {

    private val glThread = HandlerThread("GLThread").apply { start() }
    private val glHandler = Handler(glThread.looper)

    // EGL State
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglConfig: EGLConfig? = null

    // I/O Surfaces
    private var outputSurface: Surface? = null
    private var eglOutputSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var inputSurfaceTexture: SurfaceTexture? = null
    private var inputSurface: Surface? = null

    // OpenGL Program & Textures
    private var programId = 0
    private var cameraTextureId = 0
    private var lutTextureId = 0

    // Handles
    private var positionHandle = 0
    private var texCoordHandle = 0
    private var transformMatrixHandle = 0
    private var cameraTexHandle = 0
    private var lutTexHandle = 0
    private var hasLutHandle = 0

    // State
    @Volatile private var currentLutAsset: String? = null
    @Volatile private var lutChanged = false
    private val transformMatrix = FloatArray(16)
    private var outWidth = 0
    private var outHeight = 0

    // Vertex Data
    private val vertexCoords = floatArrayOf(
        -1.0f, -1.0f,   1.0f, -1.0f,
        -1.0f,  1.0f,   1.0f,  1.0f
    )
    private val textureCoords = floatArrayOf(
        0.0f, 0.0f,     1.0f, 0.0f,
        0.0f, 1.0f,     1.0f, 1.0f
    )
    private val vertexBuffer: FloatBuffer = ByteBuffer.allocateDirect(vertexCoords.size * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer().put(vertexCoords).apply { position(0) }
    private val textureBuffer: FloatBuffer = ByteBuffer.allocateDirect(textureCoords.size * 4)
        .order(ByteOrder.nativeOrder()).asFloatBuffer().put(textureCoords).apply { position(0) }

    init {
        glHandler.post { initGL() }
    }

    fun setLutAsset(assetName: String?) {
        currentLutAsset = assetName
        lutChanged = true
    }

    override fun onInputSurface(request: SurfaceRequest) {
        glHandler.post {
            // Setup input texture
            val textures = IntArray(1)
            GLES20.glGenTextures(1, textures, 0)
            cameraTextureId = textures[0]
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraTextureId)
            GLES20.glTexParameterf(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR.toFloat())
            GLES20.glTexParameterf(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR.toFloat())
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

            inputSurfaceTexture = SurfaceTexture(cameraTextureId).apply {
                setDefaultBufferSize(request.resolution.width, request.resolution.height)
                setOnFrameAvailableListener {
                    glHandler.post { drawFrame() }
                }
            }
            inputSurface = Surface(inputSurfaceTexture)
            request.provideSurface(inputSurface!!, ContextCompat.getMainExecutor(context)) {
                // Cleanup when surface is no longer needed
                glHandler.post {
                    inputSurface?.release()
                    inputSurfaceTexture?.release()
                    val texToDelete = intArrayOf(cameraTextureId)
                    GLES20.glDeleteTextures(1, texToDelete, 0)
                }
            }
        }
    }

    override fun onOutputSurface(surfaceOutput: SurfaceOutput) {
        glHandler.post {
            // 1. Simpan ukuran layar asli
            outWidth = surfaceOutput.size.width
            outHeight = surfaceOutput.size.height

            // 2. Wajib di CameraX: Beri tahu matriks transformasinya
            val identityMatrix = FloatArray(16)
            Matrix.setIdentityM(identityMatrix, 0)
            surfaceOutput.updateTransformMatrix(identityMatrix, identityMatrix)

            outputSurface = surfaceOutput.getSurface(ContextCompat.getMainExecutor(context)) { event ->
                glHandler.post {
                    if (eglOutputSurface != EGL14.EGL_NO_SURFACE) {
                        EGL14.eglDestroySurface(eglDisplay, eglOutputSurface)
                        eglOutputSurface = EGL14.EGL_NO_SURFACE
                    }
                    outputSurface = null
                }
            }

            val surfaceAttribs = intArrayOf(EGL14.EGL_NONE)
            eglOutputSurface = EGL14.eglCreateWindowSurface(eglDisplay, eglConfig, outputSurface, surfaceAttribs, 0)
            if (eglOutputSurface == EGL14.EGL_NO_SURFACE) {
                Log.e("LutSurfaceProcessor", "Failed to create EGL Output Surface")
            }
        }
    }

    private fun initGL() {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val version = IntArray(2)
        EGL14.eglInitialize(eglDisplay, version, 0, version, 1)

        val attribList = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
            EGL14.EGL_NONE
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        EGL14.eglChooseConfig(eglDisplay, attribList, 0, configs, 0, configs.size, numConfigs, 0)
        eglConfig = configs[0]

        val contextAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
        eglContext = EGL14.eglCreateContext(eglDisplay, eglConfig, EGL14.EGL_NO_CONTEXT, contextAttribs, 0)

        // Buat dummy surface pbuffer agar bisa compile shader sebelum output surface tersedia
        val pbufferAttribs = intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE)
        val pbufferSurface = EGL14.eglCreatePbufferSurface(eglDisplay, eglConfig, pbufferAttribs, 0)
        EGL14.eglMakeCurrent(eglDisplay, pbufferSurface, pbufferSurface, eglContext)

        val vertexShader = loadShader(GLES20.GL_VERTEX_SHADER, VERTEX_SHADER)
        val fragmentShader = loadShader(GLES20.GL_FRAGMENT_SHADER, FRAGMENT_SHADER)
        programId = GLES20.glCreateProgram()
        GLES20.glAttachShader(programId, vertexShader)
        GLES20.glAttachShader(programId, fragmentShader)
        GLES20.glLinkProgram(programId)

        positionHandle = GLES20.glGetAttribLocation(programId, "aPosition")
        texCoordHandle = GLES20.glGetAttribLocation(programId, "aTextureCoord")
        transformMatrixHandle = GLES20.glGetUniformLocation(programId, "uTransformMatrix")
        cameraTexHandle = GLES20.glGetUniformLocation(programId, "uCameraTexture")
        lutTexHandle = GLES20.glGetUniformLocation(programId, "uLutTexture")
        hasLutHandle = GLES20.glGetUniformLocation(programId, "uHasLut")

        Matrix.setIdentityM(transformMatrix, 0)
    }

    private fun loadLutTexture() {
        val asset = currentLutAsset
        if (asset == null) {
            if (lutTextureId != 0) {
                GLES20.glDeleteTextures(1, intArrayOf(lutTextureId), 0)
                lutTextureId = 0
            }
            return
        }

        try {
            val inputStream = context.assets.open(asset)
            val bitmap = BitmapFactory.decodeStream(inputStream)
            inputStream.close()

            if (lutTextureId == 0) {
                val textures = IntArray(1)
                GLES20.glGenTextures(1, textures, 0)
                lutTextureId = textures[0]
            }

            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, lutTextureId)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
            bitmap.recycle()
            
            Log.d("LutSurfaceProcessor", "LUT loaded successfully: $asset")
        } catch (e: IOException) {
            Log.e("LutSurfaceProcessor", "Failed to load LUT: $asset", e)
        }
    }

    private fun drawFrame() {
        inputSurfaceTexture?.updateTexImage()
        inputSurfaceTexture?.getTransformMatrix(transformMatrix)

        if (eglOutputSurface == EGL14.EGL_NO_SURFACE) return

        EGL14.eglMakeCurrent(eglDisplay, eglOutputSurface, eglOutputSurface, eglContext)
        GLES20.glViewport(0, 0, outWidth, outHeight)
        GLES20.glClearColor(0.0f, 0.0f, 0.0f, 1.0f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        if (lutChanged) {
            loadLutTexture()
            lutChanged = false
        }

        GLES20.glUseProgram(programId)

        // Setup Vertices
        GLES20.glEnableVertexAttribArray(positionHandle)
        GLES20.glVertexAttribPointer(positionHandle, 2, GLES20.GL_FLOAT, false, 8, vertexBuffer)

        GLES20.glEnableVertexAttribArray(texCoordHandle)
        GLES20.glVertexAttribPointer(texCoordHandle, 2, GLES20.GL_FLOAT, false, 8, textureBuffer)

        // Setup Camera Texture (Target 0)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraTextureId)
        GLES20.glUniform1i(cameraTexHandle, 0)

        // Setup Matrix
        GLES20.glUniformMatrix4fv(transformMatrixHandle, 1, false, transformMatrix, 0)

        // Setup LUT Texture (Target 1)
        if (lutTextureId != 0) {
            GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, lutTextureId)
            GLES20.glUniform1i(lutTexHandle, 1)
            GLES20.glUniform1i(hasLutHandle, 1)
        } else {
            GLES20.glUniform1i(hasLutHandle, 0)
        }

        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        GLES20.glDisableVertexAttribArray(positionHandle)
        GLES20.glDisableVertexAttribArray(texCoordHandle)

        EGL14.eglSwapBuffers(eglDisplay, eglOutputSurface)
    }

    private fun loadShader(type: Int, shaderCode: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, shaderCode)
        GLES20.glCompileShader(shader)
        val compiled = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, compiled, 0)
        if (compiled[0] == 0) {
            Log.e("LutSurfaceProcessor", "Could not compile shader $type: ${GLES20.glGetShaderInfoLog(shader)}")
            GLES20.glDeleteShader(shader)
            return 0
        }
        return shader
    }

    companion object {
        private const val VERTEX_SHADER = """
            uniform mat4 uTransformMatrix;
            attribute vec4 aPosition;
            attribute vec4 aTextureCoord;
            varying vec2 vTextureCoord;
            void main() {
                gl_Position = aPosition;
                vTextureCoord = (uTransformMatrix * aTextureCoord).xy;
            }
        """

        private const val FRAGMENT_SHADER = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTextureCoord;
            uniform samplerExternalOES uCameraTexture;
            uniform sampler2D uLutTexture;
            uniform int uHasLut;
            
            void main() {
                vec4 cameraColor = texture2D(uCameraTexture, vTextureCoord);
                
                // Jika filter Normal, tampilkan warna asli
                if (uHasLut == 0) {
                    gl_FragColor = vec4(cameraColor.rgb, 1.0);
                    return;
                }
                
                // 1. HAPUS SWAP R & B: Kamera selalu merender RGB yang benar.
                float r = cameraColor.r * 63.0;
                float g = cameraColor.g * 63.0;
                float b = cameraColor.b * 63.0;
                
                // 2. LOGIKA HALDCLUT (Level 8 / 512x512)
                // Diambil dari cara FFmpeg memetakan tekstur haldclut
                float bFloor = floor(b);
                float bCeil = ceil(b);
                float bFract = fract(b);
                
                float gFloor = floor(g);
                
                // Hitung koordinat dasar untuk blok Green
                float xOffset = mod(gFloor, 8.0) * 64.0;
                float yBase = floor(gFloor / 8.0);
                
                // Ambil sampel tekstur untuk layer Blue bawah (Z-index lantai)
                float x1 = r + xOffset;
                float y1 = yBase + bFloor * 8.0;
                vec2 texPos1 = vec2((x1 + 0.5) / 512.0, (y1 + 0.5) / 512.0);
                
                // Ambil sampel tekstur untuk layer Blue atas (Z-index atap)
                float x2 = r + xOffset;
                float y2 = yBase + bCeil * 8.0;
                vec2 texPos2 = vec2((x2 + 0.5) / 512.0, (y2 + 0.5) / 512.0);
                
                vec4 color1 = texture2D(uLutTexture, texPos1);
                vec4 color2 = texture2D(uLutTexture, texPos2);
                
                // Interpolasi hardware untuk R, manual interpolasi untuk B
                gl_FragColor = vec4(mix(color1.rgb, color2.rgb, bFract), 1.0);
            }
        """   
    }
}