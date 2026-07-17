package com.oney.WebRTCModule.voip

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.facebook.react.ReactApplication
import com.facebook.react.internal.featureflags.ReactNativeFeatureFlags
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Receives VoIP wake-up pushes over FCM.
 *
 * The signaling backend sends a high-priority **data** message (so this runs even
 * when the app is backgrounded or killed, and gets the temporary foreground-service
 * start exemption) with `roomName` / `displayName` / `isVideo`. We report the call
 * to Core-Telecom immediately so it rings without needing JS, and hand the room
 * details to [VoipPushRegistry] for the JS layer.
 *
 * ## Coexistence with other push-notification libraries
 *
 * Android delivers every FCM message to a single `MESSAGING_EVENT` service per app,
 * so this service also acts as a relay: messages that are not VoIP pushes (no
 * `fishjam: "voip-incoming"` discriminator) — and every token callback — are handed
 * to the app's other messaging service, named by a `VoipFallbackMessagingService`
 * manifest meta-data entry (the Expo config plugin fills it in automatically for
 * known libraries).
 * The fallback runs its real native code, so its killed-state behavior is preserved.
 *
 * Apps that need full control can instead register their own service and call
 * [handleVoipMessage] / [handleNewToken] from it.
 */
class PushNotificationService : FirebaseMessagingService() {
    // firebase-messaging 25.x delivers tokens through two distinct events with no
    // documented dispatch rules: the legacy NEW_TOKEN action -> onNewToken, and the
    // FID-registration FCM_REGISTERED action -> onRegistered. Missing either one
    // silently loses the device for VoIP pushes, so both are overridden to do the
    // same thing; updateToken and forwardTokenToFallback are idempotent per token,
    // making a double delivery harmless. The relay deliberately targets the
    // fallback's onNewToken in both cases - that is the only token callback
    // expo-notifications / RNFB implement (they predate onRegistered, whose empty
    // base impl would swallow the token).
    override fun onRegistered(token: String) {
        handleNewToken(token)
        forwardTokenToFallback(this, token)
    }

    override fun onNewToken(token: String) {
        handleNewToken(token)
        forwardTokenToFallback(this, token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        if (handleVoipMessage(this, message)) return
        forwardMessageToFallback(this, message)
    }

    // Owning the MESSAGING_EVENT slot means every FirebaseMessagingService callback
    // lands here; any not relayed silently evaporates for the fallback. VoIP has no
    // use for this one, but RNFB surfaces it to JS ("messages were dropped, resync"),
    // so pass it through.
    override fun onDeletedMessages() {
        val fallback = fallbackServiceInstance(this) ?: return
        try {
            fallback.onDeletedMessages()
        } catch (e: Exception) {
            Log.w(TAG, "Fallback messaging service failed to handle onDeletedMessages", e)
        }
    }

    companion object Dispatch {
        private const val TAG = "PushNotificationService"

        /** `<meta-data>` key naming the messaging service non-VoIP traffic is relayed to. */
        const val FALLBACK_META_KEY = "VoipFallbackMessagingService"

        /**
         * Explicit payload discriminator: a data message is ours if it carries
         * `fishjam: "voip-incoming"`.
         */
        const val DISCRIMINATOR_KEY = "fishjam"
        const val VOIP_INCOMING = "voip-incoming"

        // onRegistered and onNewToken are distinct FCM callbacks that can both deliver
        // the same token; remember the last one relayed so the fallback sees it once.
        @Volatile
        private var lastForwardedToken: String? = null

        /**
         * Handles a Fishjam VoIP push. Returns `true` if [message] carried a VoIP
         * payload (`fishjam: "voip-incoming"`) and was consumed — including pushes
         * dropped because two calls are already tracked or malformed ones. Returns
         * `false` for any other message, which the caller should route to its own
         * notification handling.
         */
        fun handleVoipMessage(context: Context, message: RemoteMessage): Boolean {
            val data = message.data
            if (data[DISCRIMINATOR_KEY] != VOIP_INCOMING) {
                return false
            }
            val roomName = data["roomName"]
            if (roomName == null) {
                Log.w(TAG, "VoIP push without roomName dropped")
                return true
            }
            val displayName = data["displayName"] ?: "Incoming call"
            val handle = data["handle"]?.takeIf { it.isNotEmpty() } ?: displayName
            val isVideo = data["isVideo"]?.toBoolean() ?: false
            val avatarUrl = data["avatarUrl"]?.takeIf { it.isNotEmpty() }
            val incoming = VoipPushRegistry.Incoming(roomName, displayName, handle, isVideo, avatarUrl)
            val appContext = context.applicationContext

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                when (CallManager.reportIncomingCall(appContext, displayName, handle, isVideo, avatarUrl)) {
                    IncomingCallSlot.CURRENT -> {
                        warmUpReact(appContext)
                        VoipPushRegistry.reportIncoming(incoming)
                    }
                    IncomingCallSlot.WAITING -> {
                        warmUpReact(appContext)
                        VoipPushRegistry.bufferWaitingIncoming(incoming)
                    }
                    IncomingCallSlot.REJECTED -> {
                        // Already tracking two calls - drop it, nothing to notify JS about.
                    }
                }
            } else {
                warmUpReact(appContext)
                VoipPushRegistry.reportIncoming(incoming)
            }
            return true
        }

        /** Records a fresh FCM token for VoIP; call from a custom service's `onNewToken`. */
        fun handleNewToken(token: String) {
            VoipPushRegistry.updateToken(token)
        }

        private fun forwardMessageToFallback(context: Context, message: RemoteMessage) {
            val fallback = fallbackServiceInstance(context) ?: return
            try {
                fallback.onMessageReceived(message)
            } catch (e: Exception) {
                Log.w(TAG, "Fallback messaging service failed to handle a message", e)
            }
        }

        private fun forwardTokenToFallback(context: Context, token: String) {
            if (token == lastForwardedToken) return
            val fallback = fallbackServiceInstance(context) ?: return
            try {
                // onNewToken is the callback every FCM library implements; onRegistered
                // only exists since firebase-messaging 25 and none of them override it.
                fallback.onNewToken(token)
                lastForwardedToken = token
            } catch (e: Exception) {
                Log.w(TAG, "Fallback messaging service failed to handle a token", e)
            }
        }

        /**
         * Instantiates the configured fallback service and injects a Context the way
         * Android would. attachBaseContext is protected on ContextWrapper, hence the
         * reflective walk.
         */
        private fun fallbackServiceInstance(context: Context): FirebaseMessagingService? {
            val className = fallbackClassName(context) ?: return null
            return try {
                val clazz = Class.forName(className)
                val instance = clazz.getDeclaredConstructor().newInstance()
                if (instance !is FirebaseMessagingService) {
                    Log.w(TAG, "$FALLBACK_META_KEY $className is not a FirebaseMessagingService")
                    return null
                }
                // A hand-constructed service has no base context; Context calls inside
                // it throw until attachBaseContext(Context) runs (Android's job during
                // normal startup). It's protected and declared on ContextWrapper, but
                // getDeclaredMethods() only sees one exact class - so walk the
                // superclass chain and take the first declaration found: the fallback's
                // own override if any (what Android would call), else ContextWrapper's.
                // parameterCount == 1 pins the (Context) overload.
                val attach = generateSequence<Class<*>>(clazz) { it.superclass }
                    .firstNotNullOfOrNull { c ->
                        c.declaredMethods.firstOrNull {
                            it.name == "attachBaseContext" && it.parameterCount == 1
                        }
                    }
                if (attach == null) {
                    Log.w(TAG, "attachBaseContext not found on $className")
                    return null
                }
                attach.isAccessible = true
                attach.invoke(instance, context.applicationContext)
                instance
            } catch (e: Exception) {
                Log.w(TAG, "Could not instantiate fallback messaging service $className", e)
                null
            }
        }

        private fun fallbackClassName(context: Context): String? =
            try {
                context.packageManager
                    .getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
                    .metaData
                    ?.getString(FALLBACK_META_KEY)
                    ?.takeIf { it.isNotBlank() }
            } catch (_: PackageManager.NameNotFoundException) {
                null
            }

        private fun warmUpReact(appContext: Context) {
            val app = appContext as? ReactApplication ?: return
            Handler(Looper.getMainLooper()).post {
                try {
                    if (ReactNativeFeatureFlags.enableBridgelessArchitecture()) {
                        app.reactHost?.start()
                    } else {
                        val manager = app.reactNativeHost.reactInstanceManager
                        if (!manager.hasStartedCreatingInitialContext()) {
                            manager.createReactContextInBackground()
                        }
                    }
                } catch (e: Exception) {
                    // Ignore React warm-up failures on push
                }
            }
        }
    }
}
