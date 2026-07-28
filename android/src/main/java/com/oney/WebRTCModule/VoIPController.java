package com.oney.WebRTCModule;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.WritableMap;
import com.oney.WebRTCModule.voip.VoIPPushRegistry;

final class VoIPController implements VoIPPushRegistry.Listener {
    private final WebRTCModule webRTCModule;

    VoIPController(WebRTCModule webRTCModule) {
        this.webRTCModule = webRTCModule;
    }

    void attach() {
        VoIPPushRegistry.INSTANCE.setListener(this);
    }

    void detach() {
        VoIPPushRegistry.INSTANCE.setListener(null);
    }

    void resolveToken(Promise promise) {
        VoIPPushRegistry.INSTANCE.resolveToken(promise);
    }

    WritableMap getPendingIncomingCall() {
        VoIPPushRegistry.Incoming incoming = VoIPPushRegistry.INSTANCE.pending();
        if (incoming == null) {
            return null;
        }
        WritableMap map = Arguments.createMap();
        map.putString("roomName", incoming.getRoomName());
        map.putString("displayName", incoming.getDisplayName());
        map.putString("handle", incoming.getHandle());
        map.putBoolean("isVideo", incoming.isVideo());
        map.putString("avatarUrl", incoming.getAvatarUrl());
        return map;
    }

    void clearPendingIncomingCall() {
        VoIPPushRegistry.INSTANCE.clearPending();
    }

    @Override
    public void onVoIPToken(String token) {
        WritableMap body = Arguments.createMap();
        body.putString("registered", token);
        webRTCModule.sendEvent("voipPushEvent", body);
    }

    @Override
    public void onVoIPIncoming(VoIPPushRegistry.Incoming incoming) {
        WritableMap payload = Arguments.createMap();
        payload.putString("roomName", incoming.getRoomName());
        payload.putString("displayName", incoming.getDisplayName());
        payload.putString("handle", incoming.getHandle());
        payload.putBoolean("isVideo", incoming.isVideo());
        payload.putString("avatarUrl", incoming.getAvatarUrl());
        WritableMap body = Arguments.createMap();
        body.putMap("incoming", payload);
        webRTCModule.sendEvent("voipPushEvent", body);
    }

    @Override
    public void onWaitingCallDeclined(VoIPPushRegistry.Incoming incoming) {
        WritableMap payload = Arguments.createMap();
        payload.putString("roomName", incoming.getRoomName());
        payload.putString("displayName", incoming.getDisplayName());
        payload.putString("handle", incoming.getHandle());
        payload.putBoolean("isVideo", incoming.isVideo());
        payload.putString("avatarUrl", incoming.getAvatarUrl());
        WritableMap body = Arguments.createMap();
        body.putMap("waitingDeclined", payload);
        webRTCModule.sendEvent("voipPushEvent", body);
    }
}
