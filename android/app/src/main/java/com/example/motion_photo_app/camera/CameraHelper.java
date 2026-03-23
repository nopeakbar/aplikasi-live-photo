package com.example.motion_photo_app.camera;

import androidx.camera.lifecycle.ProcessCameraProvider;
import android.content.Context;
import java.util.concurrent.Executor;
import java.lang.reflect.Method;

/**
 * Pakai reflection agar compiler tidak perlu resolve ListenableFuture sama sekali.
 * getInstance() dipanggil via Method.invoke() → return type jadi Object → no import needed.
 */
public class CameraHelper {

    public interface CameraProviderCallback {
        void onAvailable(ProcessCameraProvider provider);
        void onError(Exception e);
    }

    public static void getProvider(Context context, Executor executor, CameraProviderCallback callback) {
        try {
            // Reflection: hindari compiler resolve ListenableFuture dari return type getInstance()
            Method getInstance = ProcessCameraProvider.class.getMethod("getInstance", Context.class);
            Object future = getInstance.invoke(null, context); // return type = Object, bukan ListenableFuture

            // addListener juga via reflection
            Method addListener = future.getClass().getMethod("addListener", Runnable.class, Executor.class);
            addListener.invoke(future, (Runnable) () -> {
                try {
                    // get() via reflection
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
}