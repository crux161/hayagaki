#!/bin/bash

# 1. Tell SPM where to find libsumi.a (Linker Flags)
# We use -Xlinker -L to point to the folder containing libsumi.a
LIB_PATH=$(pwd)/Sources/libsumi/lib

# 2. Build for Intel (x86_64)
swift build --arch x86_64 \
    -c release \
    -Xlinker -L$LIB_PATH

# 3. Build for Apple Silicon (arm64)
swift build --arch arm64 \
    -c release \
    -Xlinker -L$LIB_PATH

# 4. Lipo (Stitch them together)
# SPM puts the binaries in .build/arch-apple-macos/release/
lipo -create -output Hayagaki \
    .build/x86_64-apple-macosx/release/Hayagaki \
    .build/arm64-apple-macosx/release/Hayagaki

echo "Universal Binary 'Hayagaki' created!"
