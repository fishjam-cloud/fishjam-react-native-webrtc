package com.oney.WebRTCModule;

import android.content.Context;
import android.graphics.SurfaceTexture;
import android.util.Log;
import android.view.TextureView;
import android.view.ViewGroup;

import androidx.annotation.NonNull;

import com.facebook.react.ReactPackage;
import com.facebook.react.bridge.NativeModule;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContext;
import com.facebook.react.uimanager.SimpleViewManager;
import com.facebook.react.uimanager.ThemedReactContext;
import com.facebook.react.uimanager.ViewManager;
import com.facebook.react.uimanager.annotations.ReactProp;

import org.webrtc.EglBase;
import org.webrtc.EglRenderer;
import org.webrtc.GlRectDrawer;
import org.webrtc.MediaStream;
import org.webrtc.VideoFrame;
import org.webrtc.VideoSink;
import org.webrtc.VideoTrack;

import java.util.Arrays;
import java.util.List;
import java.util.Objects;
import java.util.concurrent.CountDownLatch;

public class WebRTCModulePackage implements ReactPackage {
    @Override
    public List<NativeModule> createNativeModules(ReactApplicationContext reactContext) {
        return Arrays.<NativeModule>asList(new WebRTCModule(reactContext));
    }

    @Override
    public List<ViewManager> createViewManagers(ReactApplicationContext reactContext) {
        return Arrays.<ViewManager>asList(new RTCVideoViewManager(), new RTCTextureVideoViewManager());
    }

    /**
     * Renders the first video track of a {@code MediaStream} into a {@link TextureView}.
     *
     * Unlike the {@code SurfaceView}-backed {@link WebRTCView}, a {@code TextureView} is composited
     * inside the window, so parent clipping (rounded corners) and ordinary view z-order apply, at the
     * cost of one extra copy per frame. Intended for small overlays such as participant tiles placed
     * on top of a full-screen {@link WebRTCView}. The video always aspect-fills the view bounds.
     */
    public static class TextureVideoView extends ViewGroup implements TextureView.SurfaceTextureListener, VideoSink {
        private static final String TAG = WebRTCModule.TAG;

        private final TextureView textureView;
        private final EglRenderer renderer = new EglRenderer("TextureVideoView");
        private boolean rendererInitialized;
        private String streamURL;
        private VideoTrack videoTrack;

        public TextureVideoView(Context context) {
            super(context);
            textureView = new TextureView(context);
            textureView.setOpaque(false);
            textureView.setSurfaceTextureListener(this);
            addView(textureView);
        }

        @Override
        protected void onLayout(boolean changed, int l, int t, int r, int b) {
            int width = r - l;
            int height = b - t;
            textureView.measure(MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY),
                    MeasureSpec.makeMeasureSpec(height, MeasureSpec.EXACTLY));
            textureView.layout(0, 0, width, height);
            if (width > 0 && height > 0) {
                renderer.setLayoutAspectRatio((float) width / height);
            }
        }

        public void setMirror(boolean mirror) {
            renderer.setMirror(mirror);
        }

        void setStreamURL(String streamURL) {
            if (Objects.equals(streamURL, this.streamURL)) {
                return;
            }
            this.streamURL = streamURL;
            if (isAttachedToWindow()) {
                resolveTrack();
            }
        }

        @Override
        protected void onAttachedToWindow() {
            try {
                initRenderer();
                resolveTrack();
            } finally {
                super.onAttachedToWindow();
            }
        }

        @Override
        protected void onDetachedFromWindow() {
            try {
                attachTrack(null);
                if (rendererInitialized) {
                    renderer.release();
                    rendererInitialized = false;
                }
            } finally {
                super.onDetachedFromWindow();
            }
        }

        private void initRenderer() {
            if (rendererInitialized) {
                return;
            }
            EglBase.Context sharedContext = EglUtils.getRootEglBaseContext();
            if (sharedContext == null) {
                Log.e(TAG, "TextureVideoView: no shared EGL context, cannot render");
                return;
            }
            try {
                renderer.init(sharedContext, EglBase.CONFIG_PLAIN, new GlRectDrawer());
                rendererInitialized = true;
            } catch (Exception e) {
                Log.e(TAG, "TextureVideoView: failed to initialize the renderer", e);
            }
        }

        private void resolveTrack() {
            final String expectedStreamURL = streamURL;
            if (expectedStreamURL == null) {
                attachTrack(null);
                return;
            }
            ReactContext reactContext = (ReactContext) getContext();
            WebRTCModule module = reactContext.getNativeModule(WebRTCModule.class);
            if (module == null) {
                return;
            }
            ThreadUtils.runOnExecutor(() -> {
                VideoTrack track = null;
                try {
                    MediaStream stream = module.getStreamForReactTag(expectedStreamURL);
                    if (stream != null && !stream.videoTracks.isEmpty()) {
                        track = stream.videoTracks.get(0);
                    }
                } catch (Throwable tr) {
                    Log.e(TAG, "TextureVideoView: failed to look up stream " + expectedStreamURL, tr);
                }
                final VideoTrack resolved = track;
                post(() -> {
                    if (Objects.equals(expectedStreamURL, streamURL) && isAttachedToWindow()) {
                        attachTrack(resolved);
                    }
                });
            });
        }

        private void attachTrack(VideoTrack track) {
            final VideoTrack previous = videoTrack;
            if (previous == track) {
                return;
            }
            videoTrack = track;
            ThreadUtils.runOnExecutor(() -> {
                if (previous != null) {
                    try {
                        previous.removeSink(this);
                    } catch (Throwable tr) {
                        Log.w(TAG, "TextureVideoView: failed to remove sink", tr);
                    }
                }
                if (track != null) {
                    try {
                        track.addSink(this);
                    } catch (Throwable tr) {
                        Log.e(TAG, "TextureVideoView: failed to add sink", tr);
                    }
                }
            });
        }

        @Override
        public void onFrame(VideoFrame frame) {
            renderer.onFrame(frame);
        }

        @Override
        public void onSurfaceTextureAvailable(SurfaceTexture surface, int width, int height) {
            renderer.createEglSurface(surface);
        }

        @Override
        public void onSurfaceTextureSizeChanged(SurfaceTexture surface, int width, int height) {}

        @Override
        public boolean onSurfaceTextureDestroyed(SurfaceTexture surface) {
            CountDownLatch released = new CountDownLatch(1);
            renderer.releaseEglSurface(released::countDown);
            org.webrtc.ThreadUtils.awaitUninterruptibly(released);
            return true;
        }

        @Override
        public void onSurfaceTextureUpdated(SurfaceTexture surface) {}
    }

    public static class RTCTextureVideoViewManager extends SimpleViewManager<TextureVideoView> {
        private static final String REACT_CLASS = "RTCTextureVideoView";

        @NonNull
        @Override
        public String getName() {
            return REACT_CLASS;
        }

        @NonNull
        @Override
        public TextureVideoView createViewInstance(@NonNull ThemedReactContext context) {
            return new TextureVideoView(context);
        }

        @ReactProp(name = "mirror")
        public void setMirror(TextureVideoView view, boolean mirror) {
            view.setMirror(mirror);
        }

        @ReactProp(name = "streamURL")
        public void setStreamURL(TextureVideoView view, String streamURL) {
            view.setStreamURL(streamURL);
        }
    }
}
