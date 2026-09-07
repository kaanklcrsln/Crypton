#!/bin/bash
# Builds Crypton.app and a distributable Crypton.dmg.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Crypton.app"
DMG="$BUILD/Crypton.dmg"

echo "==> Cleaning"
rm -rf "$APP" "$DMG" "$BUILD/dmg-staging"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling app"
swiftc -O \
  "$ROOT"/Crypton/Sources/CryptonCore/*.swift \
  "$ROOT"/Crypton/Sources/CryptonApp/*.swift \
  -framework AppKit \
  -o "$APP/Contents/MacOS/Crypton"

echo "==> Compiling CLI"
swiftc -O \
  "$ROOT"/Crypton/Sources/CryptonCore/*.swift \
  "$ROOT"/Crypton/Sources/crypton-cli/main.swift \
  -o "$APP/Contents/Resources/crypton"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>Crypton</string>
    <key>CFBundleDisplayName</key>          <string>Crypton</string>
    <key>CFBundleExecutable</key>           <string>Crypton</string>
    <key>CFBundleIdentifier</key>           <string>com.crypton.app</string>
    <key>CFBundleVersion</key>              <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>   <string>1.0.0</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>       <string>13.0</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>LSApplicationCategoryType</key>    <string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key>     <string>Local-first encrypted folder protection.</string>
</dict>
</plist>
PLIST

echo "==> Generating icon"
ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
# Draw a padlock icon with Core Graphics via a small Swift helper.
cat > "$BUILD/icon.swift" <<'ICON'
import AppKit
let sizes = [16, 32, 64, 128, 256, 512, 1024]
for size in sizes {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let radius = CGFloat(size) * 0.22
    let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.22, blue: 0.34, alpha: 1),
               ending: NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.17, alpha: 1))?
        .draw(in: bg, angle: 90)
    let s = CGFloat(size)
    // Shackle
    let shackle = NSBezierPath()
    shackle.appendArc(withCenter: NSPoint(x: s/2, y: s*0.60), radius: s*0.17,
                      startAngle: 0, endAngle: 180)
    shackle.lineWidth = s * 0.085
    NSColor(calibratedWhite: 0.93, alpha: 1).setStroke()
    shackle.stroke()
    // Body
    let body = NSBezierPath(roundedRect: NSRect(x: s*0.27, y: s*0.24, width: s*0.46, height: s*0.38),
                            xRadius: s*0.06, yRadius: s*0.06)
    NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
    body.fill()
    // Keyhole
    let hole = NSBezierPath(ovalIn: NSRect(x: s*0.455, y: s*0.40, width: s*0.09, height: s*0.09))
    NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.22, alpha: 1).setFill()
    hole.fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    let dir = CommandLine.arguments[1]
    try? png.write(to: URL(fileURLWithPath: "\(dir)/icon_\(size)x\(size).png"))
}
ICON
swiftc -O "$BUILD/icon.swift" -framework AppKit -o "$BUILD/makeicon" 2>/dev/null
"$BUILD/makeicon" "$ICONSET"
# iconutil needs @2x variants alongside the base sizes.
for base in 16 32 128 256 512; do
  double=$((base * 2))
  [ -f "$ICONSET/icon_${double}x${double}.png" ] && \
    cp "$ICONSET/icon_${double}x${double}.png" "$ICONSET/icon_${base}x${base}@2x.png"
done
rm -f "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_64x64.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || echo "    (icon skipped)"

echo "==> Signing (ad-hoc)"
# Ad-hoc signature: sufficient to run locally. Distribution to other Macs
# requires a Developer ID certificate and notarization.
codesign --force --deep --sign - "$APP" 2>&1 | sed 's/^/    /' || true

echo "==> Building DMG"
STAGING="$BUILD/dmg-staging"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp "$ROOT/INSTALL.txt" "$STAGING/" 2>/dev/null || true

hdiutil create -volname "Crypton" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGING" "$ICONSET" "$BUILD/icon.swift" "$BUILD/makeicon"

echo ""
echo "Built:"
echo "  $APP"
echo "  $DMG"
