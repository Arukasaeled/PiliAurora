package com.alexmercerind.media_kit_video;

import android.graphics.SurfaceTexture;
import android.os.Handler;
import java.util.concurrent.atomic.AtomicBoolean;

/** 按新帧通知取图，避免弹幕重绘时重复进入原生 BufferQueue。 */
final class VideoSurfaceTexture extends SurfaceTexture {
    private final Runnable onFrameRequested;
    private final AtomicBoolean frameAvailable = new AtomicBoolean(true);

    VideoSurfaceTexture(Runnable onFrameRequested) {
        super(0);
        this.onFrameRequested = onFrameRequested;
    }

    @Override
    public void updateTexImage() {
        if (!frameAvailable.getAndSet(false)) return;
        try {
            super.updateTexImage();
        } catch (RuntimeException | Error error) {
            frameAvailable.set(true);
            throw error;
        }
    }

    @Override
    public void attachToGLContext(int textureName) {
        super.attachToGLContext(textureName);
        // 上下文重建后，即使视频暂停，也要重新取得现有画面。
        frameAvailable.set(true);
    }

    @Override
    public void setOnFrameAvailableListener(OnFrameAvailableListener listener) {
        setOnFrameAvailableListener(listener, null);
    }

    @Override
    public void setOnFrameAvailableListener(OnFrameAvailableListener listener, Handler handler) {
        // 沿用引擎指定的 Handler，注销时也将 null 原样传递。
        super.setOnFrameAvailableListener(listener == null ? null : texture -> {
            // 先发布状态，避免与 raster 持有的引擎 wrapper monitor 互相等待。
            frameAvailable.set(true);
            listener.onFrameAvailable(texture);
            // 采样仍在引擎请求完成后，保留其实际锁等待和调度相位。
            if (onFrameRequested != null) onFrameRequested.run();
        }, handler);
    }
}
