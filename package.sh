#!/bin/bash

APP_NAME="Hayagaki"
SOURCE_ICON="Resources/Hayagaki/Hayagaki.icns"
# Assuming libsumi lives here based on your previous commands
LIBSUMI_PATH="$(pwd)/Sources/libsumi/lib"

echo "🚀 Starting Universal Build for $APP_NAME..."

# --- Step 1: Build for Intel (x86_64) ---
echo "⚙️  Building for Intel (x86_64)..."
swift build --arch x86_64 -c release -Xlinker -L"$LIBSUMI_PATH"
if [ $? -ne 0 ]; then echo "💥 Intel build failed."; exit 1; fi

# --- Step 2: Build for Apple Silicon (arm64) ---
echo "⚙️  Building for Apple Silicon (arm64)..."
swift build --arch arm64 -c release -Xlinker -L"$LIBSUMI_PATH"
if [ $? -ne 0 ]; then echo "💥 Apple Silicon build failed."; exit 1; fi

# --- Step 3: Create Universal Binary (Lipo) ---
echo "🔗 Creating Universal Binary..."
# Define where SPM put the binaries
BIN_X86=".build/x86_64-apple-macosx/release/$APP_NAME"
BIN_ARM=".build/arm64-apple-macosx/release/$APP_NAME"

# Create a temporary universal binary
lipo -create -output "$APP_NAME-Universal" "$BIN_X86" "$BIN_ARM"

if [ $? -ne 0 ]; then echo "💥 Lipo failed."; exit 1; fi

# --- Step 4: Packaging ---
echo "📦 Packaging into $APP_NAME.app..."

# Create Bundle Structure
rm -rf "$APP_NAME.app" # clear old one
mkdir -p "$APP_NAME.app/Contents/MacOS"
mkdir -p "$APP_NAME.app/Contents/Resources"

# Move the Universal Binary into place
mv "$APP_NAME-Universal" "$APP_NAME.app/Contents/MacOS/$APP_NAME"
chmod +x "$APP_NAME.app/Contents/MacOS/$APP_NAME"

# --- Step 5: Handle Resources ---
# We can grab the resource bundle from either architecture (they are identical)
BUNDLE_PATH=".build/arm64-apple-macosx/release/${APP_NAME}_${APP_NAME}.bundle"

if [ -d "$BUNDLE_PATH" ]; then
    echo "📂 Copying resources..."
    cp -r "$BUNDLE_PATH" "$APP_NAME.app/Contents/MacOS/"
else
    echo "⚠  Note: No resource bundle found (Check if Package.swift defines resources)."
fi

# Copy Icon
if [ -f "$SOURCE_ICON" ]; then
    cp "$SOURCE_ICON" "$APP_NAME.app/Contents/Resources/$APP_NAME.icns"
else
    echo "⚠  Warning: Icon not found at $SOURCE_ICON"
fi

# --- Step 6: Generate Info.plist ---
cat > "$APP_NAME.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.crux.$APP_NAME</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>$APP_NAME</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# --- Step 7: Signing ---
echo "🔏 Applying Ad-Hoc Signature..."
codesign --force --deep --options runtime --sign - "$APP_NAME.app"

echo "✅ Done! '$APP_NAME.app' is now a Universal Binary."
