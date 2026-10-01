#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MeetingSidekick"
APP_BUNDLE="$PROJECT_DIR/dist/$APP_NAME.app"
# Keep executable bundles outside file-provider folders: FinderInfo may be
# reattached immediately after copying into Documents and invalidate signing.
INSTALLED_BUNDLE="$HOME/Applications/会議の相棒.app"
BUILD_PATH="${MEETING_BUILD_PATH:-/tmp/MeetingSidekick-build}"
swift build --package-path "$PROJECT_DIR" --build-path "$BUILD_PATH" --product "$APP_NAME"
BUILD_DIR="$(swift build --package-path "$PROJECT_DIR" --build-path "$BUILD_PATH" --show-bin-path)"
STAGE_DIR="$(mktemp -d /tmp/MeetingSidekick-package.XXXXXX)"
trap 'rm -rf "$STAGE_DIR"' EXIT
TMP_BUNDLE="$STAGE_DIR/$APP_NAME.app"
mkdir -p "$TMP_BUNDLE/Contents/MacOS"
cp -X "$BUILD_DIR/$APP_NAME" "$TMP_BUNDLE/Contents/MacOS/$APP_NAME"
PROJECT_DIR="$PROJECT_DIR" APP_BUNDLE="$TMP_BUNDLE" /usr/bin/python3 - <<'PY'
import plistlib,os,pathlib
info={
 'CFBundleExecutable':'MeetingSidekick','CFBundleIdentifier':'local.meeting-sidekick',
 'CFBundleName':'会議の相棒','CFBundleDisplayName':'会議の相棒','CFBundlePackageType':'APPL',
 'CFBundleVersion':'1','CFBundleShortVersionString':'0.1.0','LSMinimumSystemVersion':'15.0',
 'NSPrincipalClass':'NSApplication','NSHighResolutionCapable':True,
 'NSMicrophoneUsageDescription':'会議中の呼びかけとアイデアを、端末内で文字起こしするためにマイクを使用します。',
 'NSSpeechRecognitionUsageDescription':'会議の発言を端末内で文字にして、AIを呼ぶタイミングを判断します。',
 'NSAudioCaptureUsageDescription':'選択した会議アプリの音声を聞き、文字起こしするために使用します。',
 'NSScreenCaptureUsageDescription':'選択した会議アプリの画面を、呼び出し中のGemini Liveに共有します。',
 'MeetingProjectPath':os.environ['PROJECT_DIR']}
with open(pathlib.Path(os.environ['APP_BUNDLE'])/'Contents/Info.plist','wb') as f: plistlib.dump(info,f)
PY
rm -rf "$TMP_BUNDLE/Contents/_CodeSignature"
find "$TMP_BUNDLE" -name ".DS_Store" -delete
dot_clean "$TMP_BUNDLE" 2>/dev/null || true
xattr -rc "$TMP_BUNDLE" 2>/dev/null || true
codesign --force --deep --sign - --identifier local.meeting-sidekick "$TMP_BUNDLE" >/dev/null
codesign --verify --deep --strict "$TMP_BUNDLE"
mkdir -p "$(dirname "$APP_BUNDLE")"
if [[ "$MODE" != "--build" ]]; then
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi
mkdir -p "$(dirname "$INSTALLED_BUNDLE")"
rm -rf "$INSTALLED_BUNDLE"
ditto --norsrc --noextattr "$TMP_BUNDLE" "$INSTALLED_BUNDLE"
codesign --verify --deep --strict "$INSTALLED_BUNDLE"
ditto -c -k --keepParent --norsrc --noextattr "$TMP_BUNDLE" "$PROJECT_DIR/dist/$APP_NAME.zip"
rm -rf "$APP_BUNDLE"
ln -s "$INSTALLED_BUNDLE" "$APP_BUNDLE"
case "$MODE" in
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 2; pgrep -x "$APP_NAME" >/dev/null; echo "App process verified" ;;
  --demo) /usr/bin/open -n "$APP_BUNDLE" --args --demo --snapshot ;;
  --build) echo "$APP_BUNDLE" ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs|--telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "MeetingSidekick"' ;;
  *) echo "usage: $0 [run|--verify|--demo|--build|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
