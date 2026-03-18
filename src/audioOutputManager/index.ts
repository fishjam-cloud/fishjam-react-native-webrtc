import { androidAudioOutputManager } from './AndroidAudioOutputManager';
import { iosAudioOutputManager } from './IOSAudioOutputManager';

export {
    AudioOutputDeviceType,
    type AndroidAudioOutputChangedInfo,
} from './AndroidAudioOutputManager';

export {
    AVAudioSessionPort,
    type AudioPort,
    type AudioOutputRoute,
    RouteChangeReason,
    type IOSAudioOutputChangedInfo,
} from './IOSAudioOutputManager';

export const AudioOutputManager = {
    android: androidAudioOutputManager,
    ios: iosAudioOutputManager,
};
