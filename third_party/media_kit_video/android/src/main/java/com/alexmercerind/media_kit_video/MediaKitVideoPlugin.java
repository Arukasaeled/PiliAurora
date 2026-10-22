/**
 * This file is a part of media_kit (https://github.com/media-kit/media-kit).
 * <p>
 * Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by MIT license that can be found in the LICENSE file.
 */
package com.alexmercerind.media_kit_video;

import android.app.Activity;

import androidx.annotation.NonNull;

import java.util.HashMap;
import java.util.Map;
import java.util.Objects;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import io.flutter.view.TextureRegistry;

/**
 * MediaKitVideoPlugin
 */
public class MediaKitVideoPlugin implements FlutterPlugin, MethodCallHandler, ActivityAware {
    public static Activity activity;
    private MethodChannel channel;
    private TextureRegistry textureRegistry;
    private VideoOutputManager videoOutputManager;
    private final Object lock = new Object();

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding activityPluginBinding) {
        synchronized (lock) {
            MediaKitVideoPlugin.activity = activityPluginBinding.getActivity();

            if (videoOutputManager == null) {
                if (MediaKitVideoPlugin.activity != null && channel != null && textureRegistry != null) {
                    videoOutputManager = new VideoOutputManager(channel, textureRegistry);
                    lock.notifyAll();
                }
            }
        }
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding activityPluginBinding) {
        synchronized (lock) {
            MediaKitVideoPlugin.activity = activityPluginBinding.getActivity();

            if (videoOutputManager == null) {
                if (MediaKitVideoPlugin.activity != null && channel != null && textureRegistry != null) {
                    videoOutputManager = new VideoOutputManager(channel, textureRegistry);
                    lock.notifyAll();
                }
            }
        }
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity();
    }

    @Override
    public void onDetachedFromActivity() {
        synchronized (lock) {
            MediaKitVideoPlugin.activity = null;
        }
    }

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding flutterPluginBinding) {
        synchronized (lock) {
            channel = new MethodChannel(flutterPluginBinding.getBinaryMessenger(), "com.alexmercerind/media_kit_video");
            textureRegistry = flutterPluginBinding.getTextureRegistry();

            channel.setMethodCallHandler(this);

            if (videoOutputManager == null) {
                if (MediaKitVideoPlugin.activity != null && channel != null && textureRegistry != null) {
                    videoOutputManager = new VideoOutputManager(channel, textureRegistry);
                    lock.notifyAll();
                }
            }
        }
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
        synchronized (lock) {
            while (videoOutputManager == null) {
                try {
                    lock.wait();
                } catch (InterruptedException e) {
                    throw new RuntimeException(e);
                }
            }
            switch (call.method) {
                case "VideoOutputManager.Create": {
                    final String handle = call.argument("handle");
                    if (handle != null) {
                        try {
                            final VideoOutput videoOutput = videoOutputManager.create(Long.parseLong(handle),
                                    Boolean.TRUE.equals(call.argument("reportTimings")));
                            final HashMap<String, Object> data = new HashMap<>();
                            data.put("id", videoOutput.id);
                            data.put("frameTimelineSupported", android.os.Build.VERSION.SDK_INT >= 33);
                            result.success(data);
                        } catch (RuntimeException e) {
                            result.error("video-output-unavailable", e.getMessage(), null);
                        }
                    } else {
                        result.success(null);
                    }
                    break;
                }
                case "VideoOutputManager.SetFrameSampling": {
                    final String handle = call.argument("handle");
                    videoOutputManager.setFrameSampling(Long.parseLong(handle), outputToken(call),
                            Boolean.TRUE.equals(call.argument("enabled")));
                    result.success(null);
                    break;
                }
                case "VideoOutputManager.ConfirmSurfaceConfigured": {
                    final String handle = call.argument("handle");
                    videoOutputManager.confirmSurfaceConfigured(Long.parseLong(handle), outputToken(call));
                    result.success(null);
                    break;
                }
                case "VideoOutputManager.CreateSurface": {
                    final String handle = call.argument("handle");
                    if (handle != null) {
                        try {
                            final long wid = videoOutputManager.createSurface(
                                    Long.parseLong(handle), outputToken(call));
                            final HashMap<String, Long> data = new HashMap<>();
                            data.put("wid", wid);
                            result.success(data);
                        } catch (RuntimeException e) {
                            result.error("surface-create-failed", e.getMessage(), null);
                        }
                    } else {
                        result.success(null);
                    }
                    break;
                }
                case "VideoOutputManager.BeginOutputOperation": {
                    final String handle = call.argument("handle");
                    result.success(handle != null && videoOutputManager.beginOutputOperation(
                            Long.parseLong(handle), outputToken(call)));
                    break;
                }
                case "VideoOutputManager.InvalidateOutputGeneration": {
                    final String handle = call.argument("handle");
                    result.success(handle != null && videoOutputManager.invalidateOutputGeneration(
                            Long.parseLong(handle), outputToken(call)));
                    break;
                }
                case "VideoOutputManager.SetSurfaceTextureSize": {
                    final String handle = call.argument("handle");
                    final String width = call.argument("width");
                    final String height = call.argument("height");
                    try {
                        videoOutputManager.setSurfaceTextureSize(
                                Long.parseLong(Objects.requireNonNull(handle)),
                                outputToken(call),
                                Integer.parseInt(Objects.requireNonNull(width)),
                                Integer.parseInt(Objects.requireNonNull(height))
                        );
                        result.success(null);
                    } catch (RuntimeException e) {
                        result.error("surface-resize-failed", e.getMessage(), null);
                    }
                    break;
                }
                case "VideoOutputManager.CanWaitForSurfaceFrame": {
                    final String handle = call.argument("handle");
                    result.success(handle != null && videoOutputManager.canWaitForSurfaceFrame(
                            Long.parseLong(handle), outputToken(call)));
                    break;
                }
                case "VideoOutputManager.FrameState": {
                    final String handle = call.argument("handle");
                    result.success(handle == null ? null : videoOutputManager.frameState(Long.parseLong(handle)));
                    break;
                }
                case "VideoOutputManager.WaitForSurfaceFrame": {
                    final String handle = call.argument("handle");
                    final String request = call.argument("request");
                    final String width = call.argument("width");
                    final String height = call.argument("height");
                    videoOutputManager.waitForSurfaceFrame(
                            Long.parseLong(Objects.requireNonNull(handle)),
                            outputToken(call),
                            Objects.requireNonNull(request),
                            Integer.parseInt(Objects.requireNonNull(width)),
                            Integer.parseInt(Objects.requireNonNull(height)), result);
                    break;
                }
                case "VideoOutputManager.CancelSurfaceFrameWait": {
                    final String handle = call.argument("handle");
                    final String request = call.argument("request");
                    if (handle != null && request != null) {
                        videoOutputManager.cancelSurfaceFrameWait(
                                Long.parseLong(handle), outputToken(call), request);
                    }
                    result.success(null);
                    break;
                }
                case "VideoOutputManager.Dispose": {
                    final String handle = call.argument("handle");
                    if (handle != null) {
                        videoOutputManager.dispose(Long.parseLong(handle), result);
                    } else {
                        result.success(null);
                    }
                    break;
                }
                case "Utils.IsEmulator": {
                    result.success(Utils.isEmulator());
                    break;
                }
                default: {
                    result.notImplemented();
                    break;
                }
            }
        }
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
    }

    private static OutputOperationToken outputToken(MethodCall call) {
        return OutputOperationToken.from((Map<?, ?>) call.arguments);
    }
}
