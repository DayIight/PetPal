#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="${PETPAL_DERIVED_DATA:-$PROJECT_DIR/build/DerivedData}"
DESTINATION="${PETPAL_DESTINATION:-generic/platform=iOS Simulator}"

if ! xcode-select -p 2>/dev/null | grep -q '/Xcode.app/Contents/Developer'; then
  echo "未找到完整 Xcode。请先从 App Store 安装 Xcode，然后执行："
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
fi

xcodebuild \
  -project "$PROJECT_DIR/PetPal.xcodeproj" \
  -scheme PetPal \
  -configuration Debug \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

echo "构建成功。模拟器 App："
find "$DERIVED_DATA/Build/Products" -name 'PetPal.app' -maxdepth 4 -print
