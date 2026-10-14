#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
configuration="${1:-release}"
swift build --package-path "$project_root" -c "$configuration"
products="$(swift build --package-path "$project_root" -c "$configuration" --show-bin-path)"
app="$project_root/dist/Axon.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# A launched build may have a Finder custom icon. Keep the distributable clean;
# install-current.py restores the saved choice before first launch.
rm -f "$app"/$'Icon\r'
xattr -d com.apple.FinderInfo "$app" 2>/dev/null || true
cp "$products/TabbyNative" "$app/Contents/MacOS/TabbyNative"
cp "$project_root/Branding/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$project_root/Branding/AppIcon.icns" "$app/Contents/Resources/AppIconBlack.icns"
cp "$project_root/Branding/AppIconWhite.icns" "$app/Contents/Resources/AppIconWhite.icns"
for obsolete_icon in "$app/Contents/Resources"/AppIcon-*.icns(N); do
    rm -f "$obsolete_icon"
done
# A versioned icon resource lets LaunchServices distinguish the updated artwork.
cp "$project_root/Branding/AppIcon.icns" "$app/Contents/Resources/AppIcon-194.icns"
for resource in "$products"/*.bundle(N); do
    ditto "$resource" "$app/Contents/Resources/${resource:t}"
done
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TabbyNative</string>
<key>CFBundleIdentifier</key><string>org.tabby.native</string>
<key>CFBundleName</key><string>Axon</string>
<key>CFBundleDisplayName</key><string>Axon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.19.29</string>
<key>CFBundleVersion</key><string>194</string>
<key>CFBundleIconFile</key><string>AppIcon-194</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSMicrophoneUsageDescription</key><string>Axon uses the microphone only when you start voice input to dictate a draft.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Axon transcribes voice input into an editable draft on this Mac.</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
<key>NSHumanReadableCopyright</key><string>Axon contributors. Based on open-source SwiftTerm and Citadel.</string>
</dict></plist>
PLIST
python3 "$project_root/scripts/notices.py" "$project_root" "$app/Contents/Resources/ThirdPartyNotices"
# A stable signing identity lets macOS associate directory permission grants
# with future versions. Ad-hoc signatures bind those grants to one code hash.
# Prefer an existing Apple identity; do not create certificates or alter TCC.
signing_identity="${AXON_SIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    signing_identity="$(security find-identity -v -p codesigning | python3 -c 'import re,sys; rows=sys.stdin.read(); matches=re.findall(r"([A-F0-9]{40}) \"((?:Developer ID Application|Apple Development|Apple Distribution):[^\"]+)\"", rows); print(matches[0][0] if matches else "-")')"
fi
codesign --force --deep --sign "$signing_identity" "$app"
codesign --verify --deep --strict "$app"
if [[ "$configuration" == release ]]; then
    ditto -c -k --sequesterRsrc --keepParent "$app" "$project_root/dist/Axon-0.19.29-mac-arm64.zip"
fi
print "$app"
