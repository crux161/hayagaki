#!/bin/sh

echo "building Hayagaki via swift..."

set -xe

swift build -c release
cp -vr .build/release/Hayagaki ./hayagaki
cp -vr .build/release/Hayagaki_Hayagaki.bundle ./
