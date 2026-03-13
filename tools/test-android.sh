#!/usr/bin/env sh

set -eu

cd examples/GumTestApp

# The example app owns the Gradle wrapper and test runtime setup.
if [ ! -d node_modules ]; then
  npm install
fi

cd android
./gradlew :app:testDebugUnitTest --console=plain
