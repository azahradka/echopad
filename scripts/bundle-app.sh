#!/bin/bash
# Packages the release binary into EchoPad.app with the Liquid Glass icon, the Notetaker
# pipeline (Contents/Resources/pipeline) and a pinned, checksum-verified uv (pipeline/bin/uv).
set -euo pipefail

# uv for the pipeline: a release binary from github.com/astral-sh/uv, pinned by version and by the
# SHA-256 published in that release's uv-aarch64-apple-darwin.tar.gz.sha256. The download is cached
# under .build/uv/<version>/ so rebuilds are offline. To update: change both values together.
UV_VERSION="0.12.23"
UV_SHA256="50487ae565ccd96e499056b4674d438f4c53170202617b4c759defe0c6a1b544"
UV_ASSET="uv-aarch64-apple-darwin.tar.gz"

BINARY="${1:-.build/release/echopad}"
APP_DIR="${2:-EchoPad.app}"
VERSION="${3:-2.0.0}"
BUNDLE_ID="io.github.pieralukasz.echopad"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/echopad"

# SwiftPM resource bundles (FluidAudio ships some) must sit in Resources.
find .build -maxdepth 6 -type d -name '*_*.bundle' -path '*release*' -print0 2>/dev/null |
    while IFS= read -r -d '' bundle; do
        ditto "$bundle" "$APP_DIR/Contents/Resources/$(basename "$bundle")"
    done

# Compiles the layered Liquid Glass icon into Assets.car plus an EchoPad.icns fallback.
# actool only accepts absolute paths.
RESOURCES_DIR="$(cd "$APP_DIR/Contents/Resources" && pwd)"
if ! xcrun actool "$REPO_DIR/Resources/EchoPad.icon" \
    --compile "$RESOURCES_DIR" \
    --output-partial-info-plist "$(mktemp -t echopad-icon).plist" \
    --app-icon EchoPad --include-all-app-icons \
    --enable-on-demand-resources NO --development-region en \
    --target-device mac --minimum-deployment-target 26.0 --platform macosx \
    --errors --warnings > /dev/null; then
    # actool needs Xcode's first-launch content (xcodebuild -runFirstLaunch). Without it,
    # build a flat EchoPad.icns from the pre-rendered PNG so the bundle still has an icon.
    echo "actool failed; falling back to iconutil with Resources/AppIcon-1024.png" >&2
    ICONSET="$(mktemp -d -t echopad-icon)/EchoPad.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$REPO_DIR/Resources/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" > /dev/null
        sips -z $((size * 2)) $((size * 2)) "$REPO_DIR/Resources/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null
    done
    iconutil -c icns "$ICONSET" -o "$RESOURCES_DIR/EchoPad.icns"
fi

# The Notetaker pipeline: sources, the lockfile and the meeting-note skill. Only tracked, not
# ignored files from this list (no tests, caches, venvs or local config); it is read-only at runtime.
PIPELINE_SRC="$REPO_DIR/pipeline"
PIPELINE_DIR="$RESOURCES_DIR/pipeline"
PIPELINE_FILES=(pyproject.toml uv.lock .python-version transcribe.sh config.example.toml README.md
                .claude/skills/meeting-note/SKILL.md)
for source in "$PIPELINE_SRC"/*.py; do
    name="$(basename "$source")"
    [ "$name" = gen_test_audio.py ] || PIPELINE_FILES+=("$name")  # test-only, imported by nothing at runtime
done
for file in "${PIPELINE_FILES[@]}"; do
    if ! git -C "$REPO_DIR" ls-files --error-unmatch "pipeline/$file" > /dev/null 2>&1 ||
        git -C "$REPO_DIR" check-ignore -q "pipeline/$file"; then
        echo "pipeline/$file is missing, untracked or ignored" >&2
        exit 1
    fi
    mode=0644
    [ "$file" = transcribe.sh ] && mode=0755
    mkdir -p "$PIPELINE_DIR/$(dirname "$file")"
    install -m "$mode" "$PIPELINE_SRC/$file" "$PIPELINE_DIR/$file"
done

# uv: fetched once into the cache, checked against the pinned hash and the release's checksum file
# on every build.
UV_CACHE="$REPO_DIR/.build/uv/$UV_VERSION"
UV_URL="https://github.com/astral-sh/uv/releases/download/$UV_VERSION/$UV_ASSET"
if [ ! -f "$UV_CACHE/$UV_ASSET" ] || [ ! -f "$UV_CACHE/$UV_ASSET.sha256" ]; then
    echo "Downloading uv $UV_VERSION" >&2
    mkdir -p "$UV_CACHE"
    curl -fsSL --retry 3 -o "$UV_CACHE/$UV_ASSET.part" "$UV_URL"
    curl -fsSL --retry 3 -o "$UV_CACHE/$UV_ASSET.sha256" "$UV_URL.sha256"
    mv "$UV_CACHE/$UV_ASSET.part" "$UV_CACHE/$UV_ASSET"
fi
UV_PUBLISHED="$(awk -v asset="$UV_ASSET" '$2 == asset || $2 == "*" asset { print $1 }' "$UV_CACHE/$UV_ASSET.sha256")"
UV_ACTUAL="$(shasum -a 256 "$UV_CACHE/$UV_ASSET" | awk '{ print $1 }')"
if [ "$UV_PUBLISHED" != "$UV_SHA256" ] || [ "$UV_ACTUAL" != "$UV_SHA256" ]; then
    echo "uv $UV_VERSION checksum mismatch: pinned $UV_SHA256, published ${UV_PUBLISHED:-none}, downloaded $UV_ACTUAL" >&2
    rm -f "$UV_CACHE/$UV_ASSET" "$UV_CACHE/$UV_ASSET.sha256"
    exit 1
fi
UV_UNPACK="$(mktemp -d -t echopad-uv)"
tar -xzf "$UV_CACHE/$UV_ASSET" -C "$UV_UNPACK"
mkdir -p "$PIPELINE_DIR/bin"
install -m 0755 "$UV_UNPACK/${UV_ASSET%.tar.gz}/uv" "$PIPELINE_DIR/bin/uv"
rm -rf "$UV_UNPACK"

cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>echopad</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>EchoPad</string>
    <key>CFBundleDisplayName</key>
    <string>EchoPad</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>CFBundleIconFile</key>
    <string>EchoPad</string>
    <key>CFBundleIconName</key>
    <string>EchoPad</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>EchoPad records your side of the conversation and transcribes it on this Mac.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>EchoPad records the other side of your calls and transcribes it on this Mac. Nothing is uploaded.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Only used when you choose ScreenCaptureKit to record system audio. EchoPad never records your screen.</string>
</dict>
</plist>
PLIST

# An ad-hoc signature is pinned to this exact build's hash, so macOS would forget
# the Microphone and System Audio grants after every rebuild. Naming the bundle
# identifier as the requirement keeps them across updates.
codesign --force --deep --sign - --identifier "$BUNDLE_ID" \
    --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP_DIR"

echo "Built $APP_DIR"
