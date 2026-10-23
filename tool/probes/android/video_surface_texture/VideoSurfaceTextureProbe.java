package com.alexmercerind.media_kit_video;

import android.os.Handler;
import java.util.ArrayList;

/** 注册、请求、取图及失效交错均调用生产包装类。 */
public final class VideoSurfaceTextureProbe {
    static VideoSurfaceTexture.Context context(long generation) {
        return new VideoSurfaceTexture.Context(new OutputOperationToken(1, 1, 1, 0),
                generation, 1, System.nanoTime(), 1920, 1080);
    }
    public static void main(String[] args) {
        final ArrayList<VideoSurfaceTexture.Sample> samples = new ArrayList<>();
        final VideoSurfaceTexture texture = new VideoSurfaceTexture(samples::add);
        final Handler handler = new Handler();
        final int[] engineCalls = {0};
        texture.configureSampling(context(1));
        texture.setOnFrameAvailableListener(frame -> engineCalls[0]++, handler);
        check(texture.handler == handler, "engine handler preserved");
        final var oldListener = texture.queuedListener();
        texture.configureSampling(context(2));
        oldListener.onFrameAvailable(texture);
        texture.timestamp = System.nanoTime();
        texture.updateTexImage();
        check(samples.isEmpty() && engineCalls[0] == 1, "queued old registration forwards without sampling");
        texture.dispatchFrameAvailable();
        check(samples.isEmpty(), "request alone is not buffer evidence");
        texture.timestamp = System.nanoTime();
        texture.updateTexImage();
        check(samples.size() == 1 && samples.get(0).context.generation == 2, "new registration and buffer admitted");
        texture.dispatchFrameAvailable();
        texture.updateTexImage();
        check(samples.size() == 1, "same buffer finishes ticket without sample");
        texture.dispatchFrameAvailable();
        texture.configureSampling(context(3));
        texture.timestamp = System.nanoTime();
        texture.updateTexImage();
        check(samples.size() == 1, "in-flight ticket revoked before acquisition");
        texture.setOnFrameAvailableListener(frame -> {
            engineCalls[0]++;
            texture.timestamp = System.nanoTime();
            texture.updateTexImage();
            texture.configureSampling(context(4));
        }, handler);
        texture.dispatchFrameAvailable();
        check(samples.size() == 1, "request completing across reset retains old identity");
        texture.setOnFrameAvailableListener(frame -> {
            engineCalls[0]++;
            texture.timestamp = System.nanoTime();
            texture.updateTexImage();
        });
        texture.dispatchFrameAvailable();
        check(samples.size() == 2 && samples.get(1).context.generation == 4, "acquire before request completion publishes once");
        texture.configureSampling(null);
        texture.dispatchFrameAvailable();
        check(samples.size() == 2, "blocked registration forwards without sampling");
        texture.setOnFrameAvailableListener(null);
        final int calls = engineCalls[0];
        texture.dispatchFrameAvailable();
        check(engineCalls[0] == calls, "unregister removes forwarding");
        System.out.println("PASS: immutable registration, request/acquire association, resets and blocking");
    }
    private static void check(boolean value, String label) {
        if (!value) throw new AssertionError(label);
    }
}
