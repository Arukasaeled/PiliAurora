package com.alexmercerind.media_kit_video;

import java.util.ArrayList;

/** 主机 JVM 上检查实际采样缓冲，不涉及 GPU。 */
public final class VideoFrameSamplesProbe {
    public static void main(String[] args) {
        final VideoFrameSamples samples = new VideoFrameSamples();
        check(samples.drain().isEmpty(), "empty batch");
        for (int i = 1; i <= 80; i++) samples.add(i * 1000L);
        final ArrayList<Long> batch = samples.drain();
        check(batch.size() == 32, "bounded batch");
        check(batch.get(0) == 49 && batch.get(31) == 80, "newest samples in microseconds");
        check(samples.drain().isEmpty(), "drain releases samples");
        samples.add(81000);
        samples.clear();
        check(samples.drain().isEmpty(), "surface reset clears samples");
        System.out.println("PASS: 5 production video frame sample checks");
    }

    private static void check(boolean value, String label) {
        if (!value) throw new AssertionError(label);
    }
}
