const path = require('path');

// `install-local ../../` (postinstall) copies this repo into node_modules, but
// autolinking only picks up packages listed in package.json. Link it explicitly.
module.exports = {
    dependencies: {
        '@fishjam-cloud/react-native-webrtc': {
            root: path.join(__dirname, 'node_modules/@fishjam-cloud/react-native-webrtc'),
        },
    },
};
