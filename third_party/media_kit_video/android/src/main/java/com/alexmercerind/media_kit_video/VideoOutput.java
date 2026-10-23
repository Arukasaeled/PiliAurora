/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 * <p>
 * Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 */
package com.alexmercerind.media_kit_video;

import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.PorterDuff;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.Surface;

import java.lang.reflect.Method;
import java.util.HashMap;
import java.util.ArrayList;
import java.util.Locale;
import java.util.List;

import io.flutter.plugin.common.MethodChannel;
import io.flutter.view.TextureRegistry;


public class VideoOutput {
    public long id = 0;
    public long wid = 0;

    private Surface surface;
    private final TextureRegistry.SurfaceTextureEntry surfaceTextureEntry;

    private final Method newGlobalObjectRef;
    private final Method deleteGlobalObjectRef;
    private boolean waitUntilFirstFrameRenderedNotify;

    private long handle;
    private MethodChannel channelReference;
    private TextureRegistry textureRegistryReference;

    private final Object lock = new Object();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private long surfaceGeneration;
    private long diagnosticSequence;
    private long lastDiagnosticErrorNs;
    private int suppressedDiagnosticErrors;
    private int bufferWidth;
    private int bufferHeight;
    private final OutputOperationGate operationGate = new OutputOperationGate();
    private final List<MethodChannel.Result> disposeResults = new ArrayList<>();
    private boolean disposeComplete;
    private String disposeError;
    private long lastConsumedTimestamp;
    private long configuredAtNs;
    private long consumedFrames;
    private boolean disposed;
    private SurfaceFrameFence frameFence;
    private MethodChannel.Result frameResult;
    private final VideoFrameSamples frameSamples;
    private final VideoSurfaceTexture texture;
    private long samplingGeneration, requestSequence;
    private String samplingAdmission = "blocked";
    private boolean samplingEnabled, samplingResourceReady;
    private long samplingValidAfterNs;

    private HashMap<String, Object> samplingData() {
        final OutputOperationToken token = operationGate.activeToken();
        final HashMap<String, Object> data = new HashMap<>();
        final HashMap<String, Object> identity = new HashMap<>();
        identity.put("runtimeId", token.runtimeId);
        identity.put("loadId", token.loadId);
        identity.put("outputEpoch", token.outputEpoch);
        identity.put("configRevision", token.configRevision);
        data.put("handle", handle);
        data.put("token", identity);
        data.put("samplingGeneration", samplingGeneration);
        return data;
    }

    private void transitionSampling(String admission) {
        samplingGeneration++;
        samplingAdmission = admission;
        samplingValidAfterNs = Math.max(samplingValidAfterNs, System.nanoTime());
        if (frameSamples != null) frameSamples.clear();
        mainHandler.removeCallbacks(reportFrameSamples);
        frameReportPending = false;
        texture.configureSampling(admission.equals("active") ? new VideoSurfaceTexture.Context(
                operationGate.activeToken(), samplingGeneration, surfaceGeneration,
                samplingValidAfterNs, bufferWidth, bufferHeight) : null);
        if (operationGate.activeToken() == null) return;
        final HashMap<String, Object> data = samplingData();
        data.put("admission", admission);
        data.put("validAfterUs", samplingValidAfterNs / 1000);
        // 在同一主线程队列中先发布状态，再交付该代次的批次。
        mainHandler.post(() -> channelReference.invokeMethod("VideoOutput.FrameSampling", data));
    }

    public HashMap<String, Object> setFrameSampling(OutputOperationToken token, boolean enabled) {
        synchronized (lock) {
            if (!isCurrentToken(token)) return null;
            samplingEnabled = enabled;
            transitionSampling(enabled && samplingResourceReady ? "priming" : "blocked");
            final HashMap<String, Object> receipt = samplingData();
            receipt.put("admission", samplingAdmission);
            receipt.put("validAfterUs", samplingValidAfterNs / 1000);
            return receipt;
        }
    }

    private void blockResourceSampling() {
        samplingResourceReady = false;
        transitionSampling("blocked");
    }

    private void primeResourceSampling() {
        samplingResourceReady = true;
        transitionSampling(samplingEnabled ? "priming" : "blocked");
    }

    private boolean frameReportPending;
    private final Runnable reportFrameSamples = this::reportFrameSamples;
    private final VideoFrameSamples consumedFrameSamples = new VideoFrameSamples();
    private boolean consumedFrameReportPending;
    private final Runnable reportConsumedFrameProgress = this::reportConsumedFrameProgress;
    private void reportFrameSamples() {
        synchronized (lock) {
            frameReportPending = false;
            if (disposed || frameSamples == null || !samplingAdmission.equals("active")) return;
            final java.util.ArrayList<Long> samples = frameSamples.drain();
            if (samples.isEmpty()) return;
            final HashMap<String, Object> data = samplingData();
            data.put("kind", "refreshRequested");
            data.put("sequence", ++requestSequence);
            data.put("monotonicUs", samples);
            channelReference.invokeMethod("VideoOutput.FrameSampling", data);
        }
    }

    private void resetFrameSamples() {
        if (frameSamples != null) frameSamples.clear();
        consumedFrameSamples.clear();
        mainHandler.removeCallbacks(reportFrameSamples);
        mainHandler.removeCallbacks(reportConsumedFrameProgress);
        frameReportPending = false;
        consumedFrameReportPending = false;
    }

    private void reportConsumedFrameProgress() {
        synchronized (lock) {
            consumedFrameReportPending = false;
            final OutputOperationToken token = operationGate.activeToken();
            if (!isCurrentToken(token)) {
                consumedFrameSamples.clear();
                return;
            }
            final java.util.ArrayList<Long> samples = consumedFrameSamples.drain();
            if (samples.isEmpty()) return;
            final HashMap<String, Object> tokenData = new HashMap<>();
            tokenData.put("runtimeId", token.runtimeId);
            tokenData.put("loadId", token.loadId);
            tokenData.put("outputEpoch", token.outputEpoch);
            tokenData.put("configRevision", token.configRevision);
            final HashMap<String, Object> data = new HashMap<>();
            data.put("handle", handle);
            data.put("token", tokenData);
            data.put("consumedAtMonotonicUs", samples);
            channelReference.invokeMethod("VideoOutput.ConsumedFrames", data);
        }
    }

    private void onFrameRequested(VideoSurfaceTexture.Sample sample) {
        synchronized (lock) {
            final VideoSurfaceTexture.Context context = sample.context;
            if (disposed || frameSamples == null || !samplingAdmission.equals("active") ||
                    !isCurrentToken(context.output) || context.generation != samplingGeneration ||
                    context.resourceGeneration != surfaceGeneration ||
                    context.width != bufferWidth || context.height != bufferHeight ||
                    sample.bufferTimestamp <= samplingValidAfterNs) return;
            frameSamples.add(sample.requestedNs);
            if (!frameReportPending) {
                frameReportPending = true;
                mainHandler.postDelayed(reportFrameSamples, 250);
            }
        }
    }

    private void diagnostic(String event, Throwable error) {
        final long now = android.os.SystemClock.elapsedRealtimeNanos();
        if (error != null && lastDiagnosticErrorNs != 0 && now - lastDiagnosticErrorNs < 1000000000L) {
            suppressedDiagnosticErrors++;
            return;
        }
        if (error != null) lastDiagnosticErrorNs = now;
        final HashMap<String, Object> data = new HashMap<>();
        data.put("suppressedNativeErrors", suppressedDiagnosticErrors);
        suppressedDiagnosticErrors = 0;
        data.put("handle", handle);
        data.put("event", event);
        data.put("nativeSequence", ++diagnosticSequence);
        data.put("nativeElapsedNs", android.os.SystemClock.elapsedRealtimeNanos());
        data.put("surfaceGeneration", surfaceGeneration);
        data.put("textureId", id);
        data.put("bufferWidth", bufferWidth);
        data.put("bufferHeight", bufferHeight);
        data.put("surfaceValid", surface != null && surface.isValid());
        data.put("sdkInt", Build.VERSION.SDK_INT);
        data.put("manufacturer", Build.MANUFACTURER);
        data.put("model", Build.MODEL);
        data.put("hardware", Build.HARDWARE);
        data.put("abis", java.util.Arrays.asList(Build.SUPPORTED_ABIS));
        if (error != null) {
            data.put("error", error.toString());
            data.put("stack", Log.getStackTraceString(error));
        }
        mainHandler.post(() -> channelReference.invokeMethod("VideoOutput.Diagnostic", data));
    }

    VideoOutput(long handle, MethodChannel channelReference, TextureRegistry textureRegistryReference,
                boolean reportTimings) {
        frameSamples = reportTimings ? new VideoFrameSamples() : null;
        this.handle = handle;
        this.channelReference = channelReference;
        this.textureRegistryReference = textureRegistryReference;
        try {
            waitUntilFirstFrameRenderedNotify = false;
            // com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper is part of package:media_kit_libs_android_video & package:media_kit_libs_android_audio packages.
            // Use reflection to invoke methods of com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper.
            Class<?> mediaKitAndroidHelperClass = Class.forName("com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper");
            newGlobalObjectRef = mediaKitAndroidHelperClass.getDeclaredMethod("newGlobalObjectRef", Object.class);
            deleteGlobalObjectRef = mediaKitAndroidHelperClass.getDeclaredMethod("deleteGlobalObjectRef", long.class);
            newGlobalObjectRef.setAccessible(true);
            deleteGlobalObjectRef.setAccessible(true);
        } catch (Throwable e) {
            Log.i("media_kit", "package:media_kit_libs_android_video missing. Make sure you have added it to pubspec.yaml.");
            throw new RuntimeException("Failed to initialize com.alexmercerind.media_kit_video.VideoOutput.");
        }

        texture = new VideoSurfaceTexture(
                reportTimings ? this::onFrameRequested : null);
        try {
            surfaceTextureEntry = textureRegistryReference.registerSurfaceTexture(texture);
        } catch (RuntimeException | Error error) {
            texture.release();
            throw error;
        }
        id = surfaceTextureEntry.id();
        // This listener runs after Flutter's raster thread calls updateTexImage.
        // Frame-available alone does not mean that Flutter acquired that buffer.
        surfaceTextureEntry.setOnFrameConsumedListener(() -> {
            synchronized (lock) {
                if (disposed) return;
                final long timestamp;
                try {
                    timestamp = surfaceTextureEntry.surfaceTexture().getTimestamp();
                } catch (RuntimeException e) {
                    return;
                }
                final boolean newTimestamp = timestamp > 0 && timestamp != lastConsumedTimestamp;
                if (timestamp > configuredAtNs && newTimestamp) {
                    consumedFrames++;
                }
                final long consumedAtNs = System.nanoTime();
                if (configuredAtNs > 0 && timestamp > configuredAtNs && newTimestamp &&
                        SurfaceFrameFence.hasAutomaticEglClock(timestamp, consumedAtNs) &&
                        isCurrentToken(operationGate.activeToken())) {
                    consumedFrameSamples.add(System.nanoTime());
                    if (!consumedFrameReportPending) {
                        consumedFrameReportPending = true;
                        mainHandler.postDelayed(reportConsumedFrameProgress, 250);
                    }
                }
                if (newTimestamp && timestamp > samplingValidAfterNs &&
                        SurfaceFrameFence.hasAutomaticEglClock(timestamp, consumedAtNs) &&
                        samplingAdmission.equals("priming") && samplingEnabled && samplingResourceReady) {
                    // 此帧用于确认；活动注册从后续通知开始采样。
                    transitionSampling("active");
                }
                lastConsumedTimestamp = timestamp;
                if (!waitUntilFirstFrameRenderedNotify && timestamp > 0) {
                    waitUntilFirstFrameRenderedNotify = true;
                    final long generation = surfaceGeneration;
                    mainHandler.post(() -> {
                        synchronized (lock) {
                            if (disposed || generation != surfaceGeneration) return;
                            diagnostic("surface.first-frame", null);
                            final HashMap<String, Object> data = new HashMap<>();
                            data.put("handle", handle);
                            channelReference.invokeMethod("VideoOutput.WaitUntilFirstFrameRenderedNotify", data);
                        }
                    });
                }
                final SurfaceFrameFence fence = frameFence;
                if (fence != null && isCurrentToken(fence.token) && fence.accepts(
                        timestamp, bufferWidth, bufferHeight, surfaceGeneration)) {
                    mainHandler.post(() -> {
                        synchronized (lock) {
                            if (frameFence == fence && !disposed) finishFrameWait(true);
                        }
                    });
                }
            }
        });

        // VideoSurfaceTexture 转发引擎的 frame-available 回调；消费监听确认首帧与交接。
    }

    public void dispose(MethodChannel.Result result) {
        synchronized (lock) {
            if (disposeComplete) {
                if (disposeError == null) result.success(null);
                else result.error("surface-release-failed", disposeError, null);
                return;
            }
            disposeResults.add(result);
            if (disposed) return;
            disposed = true;
            transitionSampling("blocked");
            operationGate.revoke();
            resetFrameSamples();
            surfaceGeneration++;
            finishFrameWait(false);
        }
        Throwable releaseFailure = null;
        try {
            surfaceTextureEntry.release();
        } catch (Throwable e) {
            releaseFailure = e;
        }
        try {
            if (surface != null) surface.release();
            surface = null;
        } catch (Throwable e) {
            if (releaseFailure == null) releaseFailure = e;
        }
        final Throwable initialFailure = releaseFailure;
        if (wid == 0) {
            completeDispose(initialFailure);
            return;
        }
        // Dart 已同步解除 mpv 的 VO/wid；以实际 JNI 删除结果作为释放回执。
        Throwable failure = initialFailure;
        try {
            deleteGlobalObjectRef.invoke(null, wid);
            Log.i("media_kit", String.format(Locale.ENGLISH,
                    "com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper.deleteGlobalObjectRef: %d", wid));
            wid = 0;
        } catch (Throwable e) {
            diagnostic("surface.native-error", e);
            if (failure == null) failure = e;
        }
        completeDispose(failure);
    }

    private void completeDispose(Throwable error) {
        final List<MethodChannel.Result> waiters;
        synchronized (lock) {
            if (disposeComplete) return;
            disposeComplete = true;
            disposeError = error == null ? null : error.toString();
            waiters = new ArrayList<>(disposeResults);
            disposeResults.clear();
        }
        for (MethodChannel.Result waiter : waiters) {
            if (error == null) waiter.success(null);
            else waiter.error("surface-release-failed", disposeError, null);
        }
    }

    public boolean beginOutputOperation(OutputOperationToken token) {
        synchronized (lock) {
            final OutputOperationToken previous = operationGate.activeToken();
            if (disposed || !operationGate.begin(token)) return false;
            if (previous != null && previous.sameAs(token)) return true;
            requestSequence = 0;
            samplingEnabled = false;
            blockResourceSampling();
            configuredAtNs = System.nanoTime();
            consumedFrameSamples.clear();
            surfaceGeneration++;
            finishFrameWait(false);
            return true;
        }
    }

    public boolean invalidateOutputGeneration(OutputOperationToken token) {
        synchronized (lock) {
            if (!operationGate.isCurrent(token)) return operationGate.invalidate(token);
            blockResourceSampling();
            if (!operationGate.invalidate(token)) return false;
            consumedFrameSamples.clear();
            mainHandler.removeCallbacks(reportConsumedFrameProgress);
            consumedFrameReportPending = false;
            surfaceGeneration++;
            finishFrameWait(false);
            return true;
        }
    }

    public boolean isDisposed() {
        synchronized (lock) {
            return disposed;
        }
    }

    private boolean isCurrentToken(OutputOperationToken token) {
        return !disposed && operationGate.isCurrent(token);
    }

    public long createSurface(OutputOperationToken token) {
        synchronized (lock) {
            if (!isCurrentToken(token)) throw new IllegalStateException("Stale output generation");
            blockResourceSampling();
            surfaceGeneration++;
            lastConsumedTimestamp = 0;
            resetFrameSamples();
            finishFrameWait(false);
            // Delete previous android.view.Surface & object reference.
            try {
                if (surface != null) {
                    clearSurface();
                    surface.release();
                    surface = null;
                }
                if (wid != 0) {
                    deleteGlobalObjectRef.invoke(null, wid);
                    wid = 0;
                }
            } catch (Throwable e) {
                diagnostic("surface.native-error", e);
                // 保留未确认释放的引用，交由后续释放流程回收。
                throw new IllegalStateException("Failed to release previous Android video Surface", e);
            }
            // Create new android.view.Surface & object reference.
            try {
                waitUntilFirstFrameRenderedNotify = false;
                surface = new Surface(surfaceTextureEntry.surfaceTexture());
                wid = (long) newGlobalObjectRef.invoke(null, surface);
                diagnostic("surface.native-created", null);
            } catch (Throwable e) {
                diagnostic("surface.native-error", e);
                e.printStackTrace();
            }
            return wid;
        }
    }

    public void setSurfaceTextureSize(OutputOperationToken token, int width, int height) {
        synchronized (lock) {
            if (!isCurrentToken(token) || width <= 0 || height <= 0) {
                throw new IllegalStateException("Invalid or disposed video surface");
            }
            blockResourceSampling();
            finishFrameWait(false);
            surfaceTextureEntry.surfaceTexture().setDefaultBufferSize(width, height);
            resetFrameSamples();
            waitUntilFirstFrameRenderedNotify = false;
            configuredAtNs = System.nanoTime();
            consumedFrames = 0;
            bufferWidth = width;
            bufferHeight = height;
            diagnostic("surface.buffer-configured", null);
        }
    }

    public void confirmSurfaceConfigured(OutputOperationToken token) {
        synchronized (lock) {
            if (isCurrentToken(token)) primeResourceSampling();
        }
    }

    public boolean canWaitForSurfaceFrame(OutputOperationToken token) {
        synchronized (lock) {
            return isCurrentToken(token) && SurfaceFrameFence.hasAutomaticEglClock(
                    lastConsumedTimestamp, System.nanoTime());
        }
    }

    public HashMap<String, Object> frameState() {
        synchronized (lock) {
            final HashMap<String, Object> state = new HashMap<>();
            state.put("surfaceGeneration", surfaceGeneration);
            state.put("configuredAtNs", configuredAtNs);
            state.put("consumedFrames", consumedFrames);
            state.put("timestamp", lastConsumedTimestamp);
            state.put("disposed", disposed);
            return state;
        }
    }

    public void waitForSurfaceFrame(OutputOperationToken token, String request, int width, int height,
                                    MethodChannel.Result result) {
        synchronized (lock) {
            if (!isCurrentToken(token) || bufferWidth != width || bufferHeight != height) {
                result.error("surface-invalidated", "Video surface changed before frame wait", null);
                return;
            }
            finishFrameWait(false);
            // Dart calls this only after synchronous mpv EXTERNAL_RESIZE has
            // returned. Queued pre-configure EGL frames have older timestamps.
            frameFence = new SurfaceFrameFence(
                    request, width, height, surfaceGeneration, System.nanoTime(), token);
            frameResult = result;
            primeResourceSampling();
        }
    }

    public void cancelSurfaceFrameWait(OutputOperationToken token, String request) {
        synchronized (lock) {
            if (isCurrentToken(token) && frameFence != null &&
                    frameFence.token.sameAs(token) && frameFence.request.equals(request)) {
                finishFrameWait(false);
            }
        }
    }

    private void finishFrameWait(boolean consumed) {
        final MethodChannel.Result result = frameResult;
        frameResult = null;
        frameFence = null;
        if (result != null) result.success(consumed);
    }

    private void clearSurface() {
        try {
            final Canvas canvas = surface.lockCanvas(null);
            canvas.drawColor(Color.TRANSPARENT, PorterDuff.Mode.CLEAR);
            surface.unlockCanvasAndPost(canvas);
        } catch (Throwable e) {
            e.printStackTrace();
        }
    }

}
