#!/bin/zsh
set -eu
cd -- "${0:A:h}"
mkdir -p .build/module-cache tmp/pdfs
if (( $# == 0 )); then
  xcrun swiftc -module-name EditorSmokeTests -module-cache-path "$PWD/.build/module-cache" \
    -target "$(uname -m)-apple-macosx13.0" -framework AppKit -framework PDFKit \
    Sources/Editor.swift Tests/Smoke/main.swift -o .build/EditorSmokeTests
  .build/EditorSmokeTests "$PWD/tmp/pdfs"
  exit
fi
xcrun swiftc -module-name EditorTests -module-cache-path "$PWD/.build/module-cache" \
  -target "$(uname -m)-apple-macosx13.0" -framework AppKit -framework PDFKit \
  Sources/Editor.swift Tests/main.swift -o .build/EditorTests.new
codesign --force --sign - .build/EditorTests.new
mv -f .build/EditorTests.new .build/EditorTests
.build/EditorTests "${1:?Pass the path to the two-page RAV PDF}" "$PWD/tmp/pdfs" "${@:2}"
