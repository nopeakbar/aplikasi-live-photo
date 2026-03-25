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

    // ── KITA KEMBALI PAKAI REFLECTION AGAR LOLOS COMPILER ──
    public static void setZoomRatio(Object cameraControl, float ratio) {
        try {
            Method setZoomRatio = cameraControl.getClass().getMethod("setZoomRatio", float.class);
            setZoomRatio.invoke(cameraControl, ratio);
        } catch (Exception e) {
            e.printStackTrace();
        }
    }
}