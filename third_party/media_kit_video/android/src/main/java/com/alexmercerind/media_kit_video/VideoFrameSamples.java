package com.alexmercerind.media_kit_video;

import java.util.ArrayList;

/** 有界的纹理消费时间批次，由 VideoOutput 的锁保护。 */
final class VideoFrameSamples {
    static final int LIMIT = 32;
    private final ArrayList<Long> samples = new ArrayList<>(LIMIT);

    void add(long consumedNs) {
        if (samples.size() == LIMIT) samples.remove(0);
        samples.add(consumedNs / 1000);
    }

    ArrayList<Long> drain() {
        final ArrayList<Long> result = new ArrayList<>(samples);
        samples.clear();
        return result;
    }

    void clear() {
        samples.clear();
    }
}
