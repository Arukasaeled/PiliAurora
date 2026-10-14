package com.alexmercerind.media_kit_video;

import android.graphics.SurfaceTexture;
import android.os.Handler;

/** 在引擎 listener 返回后采样，使取图锁等待计入实际刷新请求时间。 */
final class VideoSurfaceTexture extends SurfaceTexture {
    private final Runnable onFrameRequested;

    VideoSurfaceTexture(Runnable onFrameRequested) {
        super(0);
        this.onFrameRequested = onFrameRequested;
    }

    @Override
    public void setOnFrameAvailableListener(OnFrameAvailableListener listener) {
        setOnFrameAvailableListener(listener, null);
    }

    @Override
    public void setOnFrameAvailableListener(OnFrameAvailableListener listener, Handler handler) {
        // 沿用引擎指定的 Handler，注销时也将 null 原样传递。
        super.setOnFrameAvailableListener(listener == null ? null : texture -> {
            listener.onFrameAvailable(texture);
            onFrameRequested.run();
        }, handler);
    }
}
