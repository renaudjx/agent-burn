#!/bin/bash
# Build de l'app macOS Agent Burn sans SwiftPM (swift-package est cassé par des Command Line Tools
# incohérents). Reprend les étapes de apps/macos/build.sh en mode développement.
set -euo pipefail
# Usage: SPARKLE=/path/to/dir-containing-Sparkle.framework-and-LICENSE tools/custom-build.sh
# Sparkle 2.9.6 is downloaded from https://github.com/sparkle-project/Sparkle/releases.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
MAC=$REPO/apps/macos
SPARKLE=${SPARKLE:?set SPARKLE to the extracted Sparkle release folder}
OUT=${OUT:-$REPO/custom-build}
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
[[ ! -e "$OUT" ]] || trash "$OUT"
mkdir -p "$OUT"
version="$(tr -d '\n' < "$MAC/Config/version")"

echo "== CLI Rust"
cargo build --manifest-path "$REPO/rust/Cargo.toml" --release --bin agent-burn
CLI="$REPO/rust/target/release/agent-burn"

echo "== App Swift"
cat > "$OUT/BundleModuleShim.swift" <<'SWIFT'
import Foundation
// SwiftPM synthesises Bundle.module; without it the resource bundle shipped next to the app is used.
extension Bundle { static let module = Bundle.main }
SWIFT
swiftc -swift-version 6 -O -parse-as-library -module-name AgentBurn \
  -target arm64-apple-macosx14.0 -F "$SPARKLE" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "$MAC"/Sources/AgentBurn/*.swift "$OUT/BundleModuleShim.swift" -o "$OUT/AgentBurn"

echo "== Collecteur de quotas"
swiftc -O -target arm64-apple-macosx14.0 -o "$OUT/AgentBurnQuotaCollector" \
  "$MAC"/Sources/AgentBurn/{CLIClient,QuotaCollector,QuotaHistory,QuotaJournal}.swift \
  "$MAC"/Tools/QuotaTypes.swift "$MAC"/Tools/QuotaCollectorMain.swift

echo "== Assemblage"
APP="$OUT/Agent Burn Custom.app"
mkdir -p "$APP/Contents/"{MacOS,Resources,Frameworks,Library/LaunchAgents}
cp "$MAC/Config/dev.melvynx.agent-burn.quota.plist" "$APP/Contents/Library/LaunchAgents/"
cp "$OUT/AgentBurn" "$APP/Contents/MacOS/AgentBurn"
cp "$OUT/AgentBurnQuotaCollector" "$APP/Contents/MacOS/AgentBurnQuotaCollector"
cp "$CLI" "$APP/Contents/Resources/agent-burn"
RES="$APP/Contents/Resources/AgentBurn_AgentBurn.bundle"
mkdir -p "$RES"
cp "$MAC/Sources/AgentBurn/Resources/AppIcon.icns" "$RES/"
ditto "$MAC/Sources/AgentBurn/Resources/Brands" "$RES/Brands"
cat > "$RES/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.melvynx.agent-burn.custom.resources</string>
<key>CFBundleName</key><string>AgentBurn_AgentBurn</string>
<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$RES/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$REPO/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp "$SPARKLE/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
# Build personnel : autre identifiant que l'app officielle et aucun flux Sparkle, donc pas de mise à jour qui l'écraserait.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.melvynx.agent-burn.custom</string>
<key>CFBundleName</key><string>Agent Burn Custom</string>
<key>CFBundleDisplayName</key><string>Agent Burn Custom</string>
<key>CFBundleExecutable</key><string>AgentBurn</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version-profiles</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>LSUIElement</key><false/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

echo "== Signature ad hoc"
flags=(--force --sign -)
codesign "${flags[@]}" "$APP/Contents/Resources/agent-burn"
codesign "${flags[@]}" "$APP/Contents/MacOS/AgentBurnQuotaCollector"
find "$APP/Contents/Frameworks" -type f -perm +111 -print0 | while IFS= read -r -d '' executable; do
  if file "$executable" | grep -q 'Mach-O'; then codesign "${flags[@]}" "$executable"; fi
done
find "$APP/Contents/Frameworks" -depth \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' \) -print0 | while IFS= read -r -d '' bundle; do
  codesign "${flags[@]}" "$bundle"
done
codesign "${flags[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "OK: $APP"
