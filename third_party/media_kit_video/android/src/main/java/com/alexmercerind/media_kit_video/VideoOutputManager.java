/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 * <p>
 * Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 */
package com.alexmercerind.media_kit_video;

import android.util.Log;

import java.util.HashMap;
import java.util.HashSet;
import java.util.Locale;
import java.util.Objects;

import io.flutter.plugin.common.MethodChannel;
import io.flutter.view.TextureRegistry;

public class VideoOutputManager {
    private final HashMap<Long, VideoOutput> videoOutputs = new HashMap<>();
    private final HashSet<Long> pendingDisposals = new HashSet<>();
    private final MethodChannel channelReference;
    private final TextureRegistry textureRegistryReference;
    private final Object lock = new Object();

    VideoOutputManager(MethodChannel channelReference, TextureRegistry textureRegistryReference) {
        this.channelReference = channelReference;
        this.textureRegistryReference = textureRegistryReference;
    }

    public VideoOutput create(long handle, boolean reportTimings) {
        synchronized (lock) {
            Log.i("media_kit", String.format(Locale.ENGLISH, "com.alexmercerind.media_kit_video.VideoOutputManager.create: %d", handle));
            if (pendingDisposals.contains(handle)) {
                throw new IllegalStateException("Video output release has not been confirmed");
            }
            if (!videoOutputs.containsKey(handle)) {
                final VideoOutput videoOutput = new VideoOutput(handle, channelReference, textureRegistryReference, reportTimings);
                videoOutputs.put(handle, videoOutput);
            }
            final VideoOutput output = videoOutputs.get(handle);
            if (output == null || output.isDisposed()) {
                throw new IllegalStateException("Video output release has not been confirmed");
            }
            return output;
        }
    }

    public void dispose(long handle, MethodChannel.Result result) {
        final VideoOutput output;
        synchronized (lock) {
            Log.i("media_kit", String.format(Locale.ENGLISH, "com.alexmercerind.media_kit_video.VideoOutputManager.dispose: %d", handle));
            output = videoOutputs.get(handle);
            if (output != null) pendingDisposals.add(handle);
        }
        if (output == null) result.success(null);
        else output.dispose(new MethodChannel.Result() {
            @Override
            public void success(Object value) {
                synchronized (lock) {
                    if (videoOutputs.get(handle) == output) videoOutputs.remove(handle);
                    pendingDisposals.remove(handle);
                }
                result.success(value);
            }

            @Override
            public void error(String errorCode, String errorMessage, Object errorDetails) {
                // A failed release receipt keeps the disposed output quarantined
                // under its handle so it cannot be silently replaced or reused.
                result.error(errorCode, errorMessage, errorDetails);
            }

            @Override
            public void notImplemented() {
                result.notImplemented();
            }
        });
    }

    public boolean beginOutputOperation(long handle, OutputOperationToken token) {
        synchronized (lock) {
            final VideoOutput output = videoOutputs.get(handle);
            return output != null && output.beginOutputOperation(token);
        }
    }

    public boolean invalidateOutputGeneration(long handle, OutputOperationToken token) {
        synchronized (lock) {
            final VideoOutput output = videoOutputs.get(handle);
            return output != null && output.invalidateOutputGeneration(token);
        }
    }

    public long createSurface(long handle, OutputOperationToken token) {
        synchronized (lock) {
            Log.i("media_kit", String.format(Locale.ENGLISH, "com.alexmercerind.media_kit_video.VideoOutputManager.createSurface: %d", handle));
            if (videoOutputs.containsKey(handle)) {
                return Objects.requireNonNull(videoOutputs.get(handle)).createSurface(token);
            }
            return 0;
        }
    }

    public void setSurfaceTextureSize(long handle, OutputOperationToken token, int width, int height) {
        synchronized (lock) {
            Log.i("media_kit", String.format(Locale.ENGLISH, "com.alexmercerind.media_kit_video.VideoOutputManager.setSurfaceTextureSize: %d %d %d", handle, width, height));
            if (!videoOutputs.containsKey(handle)) throw new IllegalStateException("Missing video output");
            Objects.requireNonNull(videoOutputs.get(handle)).setSurfaceTextureSize(token, width, height);
        }
    }
    public boolean canWaitForSurfaceFrame(long handle, OutputOperationToken token) {
        synchronized (lock) {
            final VideoOutput output = videoOutputs.get(handle);
            return output != null && output.canWaitForSurfaceFrame(token);
        }
    }

    public HashMap<String, Object> frameState(long handle) {
        synchronized (lock) {
            final VideoOutput output = videoOutputs.get(handle);
            return output == null ? null : output.frameState();
        }
    }

    public void waitForSurfaceFrame(long handle, OutputOperationToken token, String request, int width, int height,
                                    MethodChannel.Result result) {
        synchronized (lock) {
            final VideoOutput output = videoOutputs.get(handle);
            if (output == null) {
                result.error("surface-missing", "Missing video output", null);
            } else {
                output.waitForSurfaceFrame(token, request, width, height, result);
            }
        }
    }

    public void cancelSurfaceFrameWait(long handle, OutputOperationToken token, String request) {
        synchronized (lock) {
            final VideoOutput output = videoOutputs.get(handle);
            if (output != null) output.cancelSurfaceFrameWait(token, request);
        }
    }

}
