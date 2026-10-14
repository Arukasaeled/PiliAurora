package com.alexmercerind.media_kit_video;

import android.os.Handler;
import java.util.ArrayList;

/** 使用 Android 回调桩检查实际包装类，不测量 GPU 或显示呈现。 */
public final class VideoSurfaceTextureProbe {
    public static void main(String[] args) {
        final long[] clock = {1000};
        final ArrayList<Long> samples = new ArrayList<>();
        final VideoSurfaceTexture texture = new VideoSurfaceTexture(() -> samples.add(clock[0]));
        final Handler handler = new Handler();
        final int[] engineCalls = {0};
        final long[] requestDelay = {0};
        texture.setOnFrameAvailableListener(frame -> {
            check(frame == texture, "engine receives original texture");
            clock[0] += requestDelay[0];
            engineCalls[0]++;
        }, handler);
        check(texture.handler == handler, "engine handler preserved");
        for (long cost : new long[] {7000000, 9000000, 17000000, 7000000, 9000000}) {
            final long availableAt = clock[0];
            requestDelay[0] = cost;
            texture.dispatchFrameAvailable();
            check(samples.get(samples.size() - 1) == availableAt + cost, "sample after engine request");
            final int sampleCount = samples.size();
            clock[0] += cost;
            texture.updateTexImage();
            check(samples.size() == sampleCount, "consumption adds no phase sample");
        }
        check(engineCalls[0] == 5, "every engine callback forwarded once");
        texture.setOnFrameAvailableListener(null, handler);
        texture.dispatchFrameAvailable();
        check(samples.size() == 5 && engineCalls[0] == 5, "unregister stops both callbacks");
        texture.setOnFrameAvailableListener(frame -> engineCalls[0]++);
        texture.dispatchFrameAvailable();
        check(samples.size() == 6 && engineCalls[0] == 6, "one-argument listener wraps once");
        texture.setOnFrameAvailableListener(null);
        texture.dispatchFrameAvailable();
        check(samples.size() == 6 && engineCalls[0] == 6, "one-argument unregister");
        final RuntimeException failure = new RuntimeException("engine request failed");
        texture.setOnFrameAvailableListener(frame -> { throw failure; });
        try {
            texture.dispatchFrameAvailable();
            throw new AssertionError("engine failure must propagate");
        } catch (RuntimeException error) {
            check(error == failure, "original engine failure preserved");
        }
        check(samples.size() == 6, "failed engine listener adds no request sample");
        System.out.println("PASS: completed request sampling, consumption independence, listener and handler lifecycle");
    }

    private static void check(boolean value, String label) {
        if (!value) throw new AssertionError(label);
    }
}
