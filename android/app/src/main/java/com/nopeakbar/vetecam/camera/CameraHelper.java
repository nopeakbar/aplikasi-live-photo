package com.nopeakbar.vetecam.camera;

import androidx.camera.lifecycle.ProcessCameraProvider;
import android.content.Context;
import java.util.concurrent.Executor;
import java.lang.reflect.Method;

public class CameraHelper {

    public interface CameraProviderCallback {
        void onAvailable(ProcessCameraProvider provider);
        void onError(Exception e);
    }

    public static void getProvider(Context context, Executor executor, CameraProviderCallback callback) {
        try {
            Method getInstance = ProcessCameraProvider.class.getMethod("getInstance", Context.class);
            Object future = getInstance.invoke(null, context);

            Method addListener = future.getClass().getMethod("addListener", Runnable.class, Executor.class);
            addListener.invoke(future, (Runnable) () -> {
                try {
                    Method get = future.getClass().getMethod("get");
                    ProcessCameraProvider provider = (ProcessCameraProvider) get.invoke(future);
                    callback.onAvailable(provider);
                } catch (Exception e) {
                    callback.onError(e);
                }
            }, executor);

        } catch (Exception e) {
            callback.onError(e);
        }
    }

    // NOTE: setZoomRatio() was removed.
    //
    // The previous implementation used Java reflection to call CameraControl.setZoomRatio(),
    // which caused a silent failure for two reasons:
    //   1. CameraControl.setZoomRatio() returns ListenableFuture<Void>, not void.
    //      The reflection call cannot find a method with a void return type, so it
    //      threw an exception that was silently swallowed by the catch block.
    //   2. Even if the call succeeded, setting zoom post-session via CameraControl
    //      does not reliably trigger physical ultrawide lens switching on all devices.
    //
    // The correct approach (used in CameraManager.setZoomRatio()) is to set
    // CaptureRequest.CONTROL_ZOOM_RATIO via Camera2Interop at session build time.
    // This tells the HAL to route the optical path through the ultrawide sensor
    // before the CameraCaptureSession is even opened. No reflection needed.
}