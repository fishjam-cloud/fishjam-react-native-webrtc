import { Component, forwardRef } from 'react';
import ReactNative, { UIManager } from 'react-native';

import RTCView, { RTCPIPOptions, RTCVideoViewProps } from './RTCView';

export interface RTCPIPViewProps extends RTCVideoViewProps {
  pip?: RTCPIPOptions & {
    fallbackView?: Component;
  };
}

type RTCViewInstance = InstanceType<typeof RTCView>;

/**
 * A convenience wrapper around RTCView to handle the fallback view as a prop.
 */
const RTCPIPView = forwardRef<RTCViewInstance, RTCPIPViewProps>((props, ref) => {
    const rtcViewProps = { ...props };
    const fallbackView = rtcViewProps.pip?.fallbackView;

    delete rtcViewProps.pip?.fallbackView;

    return (
        <RTCView ref={ref}
            {...rtcViewProps}>
            {fallbackView}
        </RTCView>
    );
});

export function startPIP(ref) {
    UIManager.dispatchViewManagerCommand(
        ReactNative.findNodeHandle(ref.current),
        UIManager.getViewManagerConfig('RTCVideoView').Commands.startPIP,
        []
    );
}

export function stopPIP(ref) {
    UIManager.dispatchViewManagerCommand(
        ReactNative.findNodeHandle(ref.current),
        UIManager.getViewManagerConfig('RTCVideoView').Commands.stopPIP,
        []
    );
}

export default RTCPIPView;