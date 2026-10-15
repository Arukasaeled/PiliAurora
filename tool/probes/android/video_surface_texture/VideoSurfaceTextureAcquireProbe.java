package com.alexmercerind.media_kit_video;

import io.flutter.embedding.engine.renderer.SurfaceTextureWrapper;

/** 通过真实 Flutter wrapper 重放 30 FPS 视频叠加 120 FPS 弹幕的取图调用。 */
public final class VideoSurfaceTextureAcquireProbe {
    public static void main(String[] args) {
        final VideoSurfaceTexture texture = new VideoSurfaceTexture(() -> {});
        final SurfaceTextureWrapper wrapper = new SurfaceTextureWrapper(texture);
        texture.setOnFrameAvailableListener(frame -> wrapper.markDirty());
        wrapper.attachToGLContext(1);
        wrapper.updateTexImage();
        final int initial = texture.updateCalls;
        for (int slot = 0; slot < 120; slot++) {
            if (slot % 4 == 0) texture.dispatchFrameAvailable();
            wrapper.updateTexImage();
        }
        check(texture.updateCalls - initial == 30,
                "30 video frames must cause 30 acquisitions, actual=" + (texture.updateCalls - initial));
        final int beforePause = texture.updateCalls;
        for (int i = 0; i < 120; i++) wrapper.updateTexImage();
        check(texture.updateCalls == beforePause, "paused video reuses current image");
        texture.dispatchFrameAvailable();
        texture.dispatchFrameAvailable();
        wrapper.updateTexImage();
        check(texture.updateCalls == beforePause + 1, "pending frames coalesce to latest image");
        wrapper.detachFromGLContext();
        wrapper.attachToGLContext(2);
        wrapper.updateTexImage();
        check(texture.updateCalls == beforePause + 2, "reattach reacquires existing image");
        wrapper.release();
        wrapper.updateTexImage();
        check(texture.updateCalls == beforePause + 2, "released wrapper cannot acquire");
        final VideoSurfaceTexture withoutTimings = new VideoSurfaceTexture(null);
        final SurfaceTextureWrapper retryWrapper = new SurfaceTextureWrapper(withoutTimings);
        withoutTimings.setOnFrameAvailableListener(frame -> retryWrapper.markDirty());
        withoutTimings.updateFailure = new IllegalStateException("temporary acquisition failure");
        try {
            retryWrapper.updateTexImage();
            throw new AssertionError("acquisition failure must propagate");
        } catch (IllegalStateException error) {
            check(error == withoutTimings.updateFailure, "original failure preserved");
        }
        withoutTimings.updateFailure = null;
        retryWrapper.updateTexImage();
        retryWrapper.updateTexImage();
        check(withoutTimings.updateCalls == 2, "failed acquisition can retry without a new notification");
        withoutTimings.dispatchFrameAvailable();
        retryWrapper.updateTexImage();
        check(withoutTimings.updateCalls == 3, "new frames work without timing collection");
        retryWrapper.release();
        System.out.println("PASS: 30 FPS video / 120 FPS repaint acquires 30 images; pause, resume, coalescing and reattach preserved");
    }

    private static void check(boolean value, String label) {
        if (!value) throw new AssertionError(label);
    }
}
