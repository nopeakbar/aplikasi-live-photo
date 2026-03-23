package com.example.motion_photo_app.camera

import android.content.Context
import android.view.View
import androidx.camera.view.PreviewView
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class CameraPreviewFactory(
    private val cameraManager: CameraManager
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        return CameraPreviewPlatformView(context, cameraManager)
    }
}

class CameraPreviewPlatformView(
    context: Context,
    private val cameraManager: CameraManager
) : PlatformView {

    private val previewView: PreviewView = PreviewView(context).apply {
        implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        scaleType = PreviewView.ScaleType.FILL_CENTER
    }

    init {
        // Pasang PreviewView ke CameraManager supaya bisa di-bind ke Preview use case
        cameraManager.attachPreviewView(previewView)
    }

    override fun getView(): View = previewView

    override fun dispose() {
        cameraManager.detachPreviewView()
    }
}