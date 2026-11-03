#!/bin/zsh
set -eu
cd -- "${0:A:h}"
APP="${PWD}/Simple PDF Editor.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" .build/module-cache
xcrun swiftc -O -module-name SimplePDFEditor -module-cache-path "$PWD/.build/module-cache" \
  -target "$(uname -m)-apple-macosx13.0" -framework AppKit -framework PDFKit \
  Sources/Editor.swift Sources/main.swift -o "$PWD/.build/SimplePDFEditor.new"
mv -f "$PWD/.build/SimplePDFEditor.new" "$APP/Contents/MacOS/SimplePDFEditor"
cp Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$APP"
print "Built: $APP"
