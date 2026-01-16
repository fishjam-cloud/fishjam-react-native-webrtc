import { requireNativeComponent, ViewProps } from 'react-native';

/**
 * Native prop validation was removed from RN in:
 * https://github.com/facebook/react-native/commit/8dc3ba0444c94d9bbb66295b5af885bff9b9cd34
 *
 * So we list them here for documentation purposes.
 */
export interface RTCVideoViewProps extends ViewProps {
  /**
   * Indicates whether the video specified by {@link #streamURL} should be
   * mirrored during rendering. Commonly, applications choose to mirror the
   * user-facing camera.
   *
   * mirror: boolean
   */
  mirror?: boolean;

  /**
   * In the fashion of
   * https://www.w3.org/TR/html5/embedded-content-0.html#dom-video-videowidth
   * and https://www.w3.org/TR/html5/rendering.html#video-object-fit,
   * resembles the CSS style object-fit.
   *
   * objectFit: 'contain' | 'cover'
   *
   * Defaults to 'cover'.
   */
  objectFit?: 'contain' | 'cover';

  /**
   * URL / id of the stream that should be rendered.
   *
   * streamURL: string
   */
  streamURL?: string;
  /**
   * Similarly to the CSS property z-index, specifies the z-order of this
   * RTCView in the stacking space of all RTCViews. When RTCViews overlap,
   * zOrder determines which one covers the other. An RTCView with a larger
   * zOrder generally covers an RTCView with a lower one.
   *
   * Non-overlapping RTCViews may safely share a z-order (because one does not
   * have to cover the other).
   *
   * The support for zOrder is platform-dependent and/or
   * implementation-specific. Thus, specifying a value for zOrder is to be
   * thought of as giving a hint rather than as imposing a requirement. For
   * example, video renderers such as RTCView are commonly implemented using
   * OpenGL and OpenGL views may have different numbers of layers in their
   * stacking space. Android has three: a layer bellow the window (aka
   * default), a layer bellow the window again but above the previous layer
   * (aka media overlay), and above the window. Consequently, it is advisable
   * to limit the number of utilized layers in the stacking space to the
   * minimum sufficient for the desired display. For example, a video call
   * application usually needs a maximum of two zOrder values: 0 for the
   * remote video(s) which appear in the background, and 1 for the local
   * video(s) which appear above the remote video(s).
   *
   * zOrder: number
   */
  zOrder?: number;


  /**
   * Picture in picture options for this view. Disabled if not supplied.
   *
   * Note: this should only be generally only used with remote video tracks,
   * as the local camera may stop while in the background.
   *
   * iOS: Requires iOS 15.0 or above, and the PIP background mode capability.
   * Android: The library handles PIP automatically. Requires Android 8.0 (API level 26) or above.
   * You must add `android:supportsPictureInPicture="true"` to your Activity in AndroidManifest.xml.
   */
  pip?: RTCPIPOptions;

  /**
   * Callback function that is called when the dimensions of the video change.
   *
   * @param {Object} event - The event object containing the new dimensions.
   * @param {Object} event.nativeEvent - The native event data.
   * @param {number} event.nativeEvent.width - The width of the video.
   * @param {number} event.nativeEvent.height - The height of the video.
   */
  onDimensionsChange?: (event: { nativeEvent: { width: number; height: number } }) => void;
}

export interface RTCPIPOptions {

  /**
   * Whether PIP can be launched from this view.
   *
   * Defaults to true.
   */
  enabled?: boolean;

  /**
   * The preferred size of the PIP window.
   */
  preferredSize?: {
    width: number;
    height: number;
  },

  /**
   * Indicates whether Picture in Picture starts automatically
   * when the app transitions to the background.
   *
   * Defaults to true.
   *
   * iOS: See AVPictureInPictureController.canStartPictureInPictureAutomaticallyFromInline
   */
  startAutomatically?: boolean;

  /**
   * Indicates whether Picture in Picture should stop automatically
   * when the app returns to the foreground.
   *
   * Defaults to true.
   *
   * Note: This property only has effect on iOS. On Android, PIP mode exit is
   * controlled by the system - when the user expands the PIP window or returns
   * to the app, Android automatically exits PIP mode. There is no way to keep
   * PIP active while the app is in the foreground on Android.
   */
  stopAutomatically?: boolean;

  /**
   * Allows the local camera to continue running while in Picture in Picture mode.
   *
   * iOS only. Requires iOS 16.0+ and device support for multitasking camera access.
   *
   * Defaults to false.
   */
  allowsCameraInBackground?: boolean;
}

export default requireNativeComponent<RTCVideoViewProps>('RTCVideoView');
