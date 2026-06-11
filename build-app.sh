#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/Cron Monitor Desktop Widget.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"
GENERATED_DIR="$ROOT/Sources/CronMonitorDesktopWidget/Generated"
GENERATED="$GENERATED_DIR/BundledCrontab.swift"

mkdir -p "$MACOS" "$RESOURCES"
mkdir -p "$GENERATED_DIR"

CRONTAB_B64="$(/usr/bin/crontab -l 2>/dev/null | /usr/bin/base64 | /usr/bin/tr -d '\n' || true)"
cat > "$GENERATED" <<SWIFT
import Foundation

let embeddedCrontabBase64 = "$CRONTAB_B64"

func embeddedCrontab() -> String {
    guard
        let data = Data(base64Encoded: embeddedCrontabBase64),
        let text = String(data: data, encoding: .utf8)
    else {
        return ""
    }

    return text
}
SWIFT

CLANG_MODULE_CACHE_PATH="$ROOT/.clang-module-cache" \
SWIFTPM_HOME="$ROOT/.swiftpm-cache" \
swift build -c release --package-path "$ROOT"

cp "$ROOT/.build/release/CronMonitorDesktopWidget" "$MACOS/CronMonitorDesktopWidget"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/crontab -l > "$RESOURCES/crontab.txt" 2>/dev/null || true

echo "Built: $APP"
