#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="${PETPAL_TEST_DERIVED_DATA:-$PROJECT_DIR/build/TestDerivedData}"

if ! xcode-select -p 2>/dev/null | grep -q '/Xcode.app/Contents/Developer'; then
  echo "未找到完整 Xcode。请先从 App Store 安装 Xcode。"
  exit 1
fi

DEVICE_ID="${PETPAL_TEST_DEVICE_ID:-}"
if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID="$(xcrun simctl list devices available | awk -F '[()]' '/iPhone/ { print $2; exit }')"
fi

if [[ -z "$DEVICE_ID" ]]; then
  echo "没有可用的 iPhone 模拟器。请在 Xcode Settings > Components 中安装 iOS Simulator 运行时。"
  exit 1
fi

echo "使用模拟器：$DEVICE_ID"
xcodebuild \
  -project "$PROJECT_DIR/PetPal.xcodeproj" \
  -scheme PetPal \
  -configuration Debug \
  -destination "id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  test
