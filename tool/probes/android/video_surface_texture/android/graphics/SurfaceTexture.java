package android.graphics;

import android.os.Handler;
import java.util.concurrent.CountDownLatch;

/** 主机 JVM 探针的回调桩；不创建 GL 或原生 Surface。 */
public class SurfaceTexture {
    public interface OnFrameAvailableListener {
        void onFrameAvailable(SurfaceTexture texture);
    }

    private OnFrameAvailableListener listener;
    public Handler handler;
    public int updateCalls;
    public RuntimeException updateFailure;
    public final CountDownLatch updateEntered = new CountDownLatch(1);
    private CountDownLatch updateContinue;

    public SurfaceTexture(int textureName) {}

    public void setOnFrameAvailableListener(OnFrameAvailableListener listener) {
        setOnFrameAvailableListener(listener, null);
    }

    public void setOnFrameAvailableListener(OnFrameAvailableListener listener, Handler handler) {
        this.listener = listener;
        this.handler = handler;
    }

    public void dispatchFrameAvailable() {
        if (listener != null) listener.onFrameAvailable(this);
    }

    public void blockUpdate() {
        updateContinue = new CountDownLatch(1);
    }

    public void releaseUpdate() {
        if (updateContinue != null) updateContinue.countDown();
    }

    public void updateTexImage() {
        updateCalls++;
        if (updateFailure != null) throw updateFailure;
        updateEntered.countDown();
        if (updateContinue != null) {
            try {
                updateContinue.await();
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new IllegalStateException(error);
            }
        }
    }

    public void release() {}
    public void detachFromGLContext() {}
    public void attachToGLContext(int name) {}
    public void getTransformMatrix(float[] matrix) {}
}
