/**
 * Sample React Native App
 * https://github.com/facebook/react-native
 *
 * @format
 * @flow strict-local
 */

import React, {useState, useRef} from 'react';
import {
  Button,
  SafeAreaView,
  StyleSheet,
  View,
  StatusBar,
} from 'react-native';
import { Colors } from 'react-native/Libraries/NewAppScreen';
import { mediaDevices, startIOSPIP, stopIOSPIP, RTCPIPView } from 'react-native-webrtc';
// Temporary instrumentation for RCA of "H264 encoder stuck after background".
// See also: ios/RCTWebRTC/videoEffects/H264DebugFrameCounter.{h,m}
// If you have a peer connection in your real app, import
// startH264DebugStatsPoller from './h264DebugStatsPoller' and call it with
// your RTCPeerConnection to correlate with the native [H264-DEBUG] logs.
// eslint-disable-next-line no-unused-vars
import { startH264DebugStatsPoller } from './h264DebugStatsPoller';


const App = () => {
  const view = useRef()
  const [stream, setStream] = useState(null);
  const start = async () => {
    console.log('start');
    if (!stream) {
      try {
        const s = await mediaDevices.getUserMedia({ video: true });
        // Activate the native frame counter for the capture track so the
        // per-second [H264-DEBUG] frames log fires even without a peer
        // connection. Comment this out to disable.
        const videoTrack = s.getVideoTracks()[0];
        if (videoTrack && typeof videoTrack._setVideoEffects === 'function') {
          try {
            videoTrack._setVideoEffects(['h264DebugFrameCounter']);
            console.log('[H264-DEBUG-JS] frame counter activated on', videoTrack.id);
          } catch (e) {
            console.warn('[H264-DEBUG-JS] failed to activate frame counter:', e);
          }
        }
        setStream(s);
      } catch(e) {
        console.error(e);
      }
    }
  };
  const startPIP = () => {
    startIOSPIP(view);
  };
  const stopPIP = () => {
    stopIOSPIP(view);
  };
  const stop = () => {
    console.log('stop');
    if (stream) {
      stream.release();
      setStream(null);
    }
  };
  let pipOptions = {
    startAutomatically: true,
    fallbackView: (<View style={{ height: 50, width: 50, backgroundColor: 'red' }} />),
    preferredSize: {
      width: 400,
      height: 800,
    }
  }
  return (
    <>
      <StatusBar barStyle="dark-content" />
      <SafeAreaView style={styles.body}>
      {
        stream &&
        <RTCPIPView
            ref={view}
            streamURL={stream.toURL()}
            style={styles.stream}
            iosPIP={pipOptions} >
        </RTCPIPView>
      }
        <View
          style={styles.footer}>
          <Button
            title = "Start"
            onPress = {start} />
          <Button
            title = "Start PIP"
            onPress = {startPIP} />
          <Button
            title = "Stop PIP"
            onPress = {stopPIP} />
          <Button
            title = "Stop"
            onPress = {stop} />
        </View>
      </SafeAreaView>
    </>
  );
};

const styles = StyleSheet.create({
  body: {
    backgroundColor: Colors.white,
    ...StyleSheet.absoluteFill
  },
  stream: {
    flex: 1
  },
  footer: {
    backgroundColor: Colors.lighter,
    position: 'absolute',
    bottom: 0,
    left: 0,
    right: 0
  },
});

export default App;
