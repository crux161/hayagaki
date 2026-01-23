#!/bin/bash

APP_NAME="Hayagaki"
SOURCE_ICON="Resources/Hayagaki/Hayagaki.icns"

echo "🚀 Building $APP_NAME via Swift..."
swift build -c release

if [ $? -ne 0 ]; then
    echo "💥 Build failed."
    exit 1
fi

echo "📦 Packaging into $APP_NAME.app..."

# 1. Create the App Bundle Structure
mkdir -p "$APP_NAME.app/Contents/MacOS"
mkdir -p "$APP_NAME.app/Contents/Resources"

# 2. Copy the Binary
cp .build/release/$APP_NAME "$APP_NAME.app/Contents/MacOS/"

# 3. Copy the SPM Resource Bundle (Shaders/Headers)
# Note: We place this inside MacOS so the binary finds it relative to itself via Bundle.module
if [ -d ".build/release/${APP_NAME}_${APP_NAME}.bundle" ]; then
    cp -r ".build/release/${APP_NAME}_${APP_NAME}.bundle" "$APP_NAME.app/Contents/MacOS/"
fi

# 4. Copy the Icon
if [ -f "$SOURCE_ICON" ]; then
    cp "$SOURCE_ICON" "$APP_NAME.app/Contents/Resources/$APP_NAME.icns"
else
    echo "⚠️ Warning: Icon not found at $SOURCE_ICON"
fi

# 5. Generate Info.plist (Essential for the icon to show up)
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
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# 6. Ad-Hoc Signing (NEW STEP)
echo "🔏 Applying Ad-Hoc Signature..."
# --force: Overwrite any existing signature
# --deep: Sign frameworks/libraries inside the bundle
# --sign -: Sign with "Ad-Hoc" (no identity required)
codesign --force --deep --options runtime --sign - "$APP_NAME.app"

echo "✅ Done! Run open $APP_NAME.app to test."
