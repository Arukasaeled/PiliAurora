package com.alexmercerind.media_kit_video;

import android.graphics.SurfaceTexture;
import android.os.Handler;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.Consumer;

/** 通知身份在注册时冻结；请求完成和实际取图共同确认相位候选。 */
final class VideoSurfaceTexture extends SurfaceTexture {
    static final class Context {
        final OutputOperationToken output;
        final long generation, resourceGeneration, validAfterNs;
        final int width, height;
        Context(OutputOperationToken output, long generation, long resourceGeneration,
                long validAfterNs, int width, int height) {
            this.output = output;
            this.generation = generation;
            this.resourceGeneration = resourceGeneration;
            this.validAfterNs = validAfterNs;
            this.width = width;
            this.height = height;
        }
    }
    static final class Sample {
        final Context context;
        final long requestedNs, bufferTimestamp;
        Sample(Context context, long requestedNs, long bufferTimestamp) {
            this.context = context;
            this.requestedNs = requestedNs;
            this.bufferTimestamp = bufferTimestamp;
        }
    }
    private static final class Ticket {
        final Context context;
        long requestedNs, timestamp;
        boolean acquired, finished;
        Ticket(Context context) { this.context = context; }
    }
    private final Consumer<Sample> onFrameRequested;
    private final AtomicBoolean frameAvailable = new AtomicBoolean(true);
    private final Object samplingLock = new Object();
    private Context context;
    private Ticket pending;
    private long lastTimestamp;
    private OnFrameAvailableListener engineListener;
    private Handler engineHandler;

    VideoSurfaceTexture(Consumer<Sample> onFrameRequested) {
        super(0);
        this.onFrameRequested = onFrameRequested;
    }

    void configureSampling(Context next) {
        synchronized (samplingLock) {
            context = next;
            if (pending != null) pending.finished = true;
            pending = null;
        }
        installListener();
    }

    @Override
    public void updateTexImage() {
        if (!frameAvailable.getAndSet(false)) return;
        final Ticket ticket;
        synchronized (samplingLock) { ticket = pending; pending = null; }
        try {
            super.updateTexImage();
        } catch (RuntimeException | Error error) {
            frameAvailable.set(true);
            if (ticket != null) synchronized (samplingLock) { ticket.finished = true; }
            throw error;
        }
        final long timestamp = getTimestamp();
        Sample sample = null;
        synchronized (samplingLock) {
            if (ticket != null) {
                ticket.acquired = true;
                ticket.timestamp = timestamp;
                if (timestamp <= lastTimestamp) ticket.finished = true;
                sample = complete(ticket);
            }
            lastTimestamp = Math.max(lastTimestamp, timestamp);
        }
        if (sample != null) onFrameRequested.accept(sample);
    }

    private Sample complete(Ticket ticket) {
        if (ticket.finished || !ticket.acquired || ticket.requestedNs == 0) return null;
        ticket.finished = true;
        final Context identity = ticket.context;
        if (identity != context || ticket.timestamp <= identity.validAfterNs ||
                !SurfaceFrameFence.hasAutomaticEglClock(ticket.timestamp, System.nanoTime())) return null;
        return new Sample(identity, ticket.requestedNs, ticket.timestamp);
    }

    @Override
    public void attachToGLContext(int textureName) {
        super.attachToGLContext(textureName);
        frameAvailable.set(true);
    }

    @Override
    public void setOnFrameAvailableListener(OnFrameAvailableListener listener) {
        setOnFrameAvailableListener(listener, null);
    }

    @Override
    public void setOnFrameAvailableListener(OnFrameAvailableListener listener, Handler handler) {
        engineListener = listener;
        engineHandler = handler;
        installListener();
    }

    private void installListener() {
        final OnFrameAvailableListener listener = engineListener;
        final Context registration;
        synchronized (samplingLock) { registration = context; }
        super.setOnFrameAvailableListener(listener == null ? null : texture -> {
            frameAvailable.set(true);
            final Ticket ticket;
            synchronized (samplingLock) {
                ticket = registration != null && registration == context && onFrameRequested != null
                        ? new Ticket(registration) : null;
                if (ticket != null) {
                    if (pending != null) pending.finished = true;
                    pending = ticket;
                }
            }
            // 引擎 wrapper 持锁期间可能取图；跨线程交付不持 samplingLock。
            listener.onFrameAvailable(texture);
            final long requestedNs = System.nanoTime();
            Sample sample = null;
            synchronized (samplingLock) {
                if (ticket != null) {
                    ticket.requestedNs = requestedNs;
                    sample = complete(ticket);
                }
            }
            if (sample != null) onFrameRequested.accept(sample);
        }, engineHandler);
    }
}
