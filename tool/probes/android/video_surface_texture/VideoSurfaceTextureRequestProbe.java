package com.alexmercerind.media_kit_video;

import io.flutter.embedding.engine.renderer.SurfaceTextureWrapper;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

/** 编译实际 Flutter wrapper，用其 monitor 检查采样与请求的顺序。 */
public final class VideoSurfaceTextureRequestProbe {
    public static void main(String[] args) throws Exception {
        final long screen = 8333;
        long previousSlot = -1;
        for (int index = 0; index < 12; index++) {
            final long arrivalUs = 1000 + index * 2 * screen;
            final long waitUs = index % 2 == 0 ? 0 : 9000;
            final AtomicLong clock = new AtomicLong(arrivalUs);
            final AtomicLong sample = new AtomicLong(-1);
            final AtomicLong request = new AtomicLong(-1);
            final AtomicInteger consumed = new AtomicInteger();
            final VideoSurfaceTexture texture = new VideoSurfaceTexture(() -> sample.set(clock.get()));
            final SurfaceTextureWrapper wrapper = new SurfaceTextureWrapper(texture, consumed::incrementAndGet);
            final CountDownLatch callbackEntered = new CountDownLatch(1);
            texture.setOnFrameAvailableListener(frame -> {
                callbackEntered.countDown();
                // 与 FlutterRenderer 相同：markDirty 返回后才请求引擎帧。
                wrapper.markDirty();
                request.set(clock.get());
            });

            final Thread raster = new Thread(wrapper::updateTexImage);
            final Thread arrival = new Thread(texture::dispatchFrameAvailable);
            boolean sampledWhileBlocked = false;
            if (waitUs > 0) {
                texture.blockUpdate();
                try {
                    raster.start();
                    check(texture.updateEntered.await(2, TimeUnit.SECONDS), "raster entered wrapper");
                    arrival.start();
                    check(callbackEntered.await(2, TimeUnit.SECONDS), "engine listener entered");
                    final long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
                    while (arrival.getState() != Thread.State.BLOCKED && System.nanoTime() < deadline) {
                        Thread.sleep(1);
                    }
                    check(arrival.getState() == Thread.State.BLOCKED, "request waits on actual wrapper monitor");
                    sampledWhileBlocked = sample.get() != -1;
                    clock.addAndGet(waitUs);
                } finally {
                    texture.releaseUpdate();
                    raster.join(2000);
                    arrival.join(2000);
                }
                check(!raster.isAlive() && !arrival.isAlive(), "callbacks completed");
                check(!sampledWhileBlocked, "phase sample must wait for engine request");
                check(consumed.get() == 1, "consumption confirmation preserved");
                wrapper.updateTexImage();
                check(texture.updateCalls == 2, "notification during acquisition is preserved");
                wrapper.updateTexImage();
                check(texture.updateCalls == 2, "next repaint reuses image after pending notification consumed");
            } else {
                texture.dispatchFrameAvailable();
            }
            check(sample.get() == request.get(), "sample and completed request share clock");
            final long sampleSlot = sample.get() / screen + 1;
            final long requestSlot = request.get() / screen + 1;
            check(sampleSlot == requestSlot, "sample identifies request slot");
            if (previousSlot >= 0) {
                check(requestSlot - previousSlot == (index % 2 == 0 ? 1 : 3), "alternating request cadence");
            }
            previousSlot = requestSlot;
        }
        System.out.println("PASS: actual Flutter wrapper contention is included in request samples; alternating 0/9ms waits follow 3/1 request slots");
    }

    private static void check(boolean value, String label) {
        if (!value) throw new AssertionError(label);
    }
}
