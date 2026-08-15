#!/usr/bin/env bash
# 用法: ./scripts/build-ipa.sh [版本号]  默认 0.1.0
# 产物: dist/OhMyMeme-{版本}.ipa
# 签名: 无签名构建（CODE_SIGNING_ALLOWED=NO）。Xcode 16+ / iOS 18 SDK 禁止 ad-hoc 签名，
#       故产出未签名 ipa，由 AltStore/SideStore 安装时用用户免费 Apple ID 重签。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
CONFIGURATION="Release"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen 未安装，请先执行: brew install xcodegen"
  exit 1
fi

echo "==> 生成 Xcode 工程"
xcodegen generate

echo "==> 编译 iphoneos（未签名）"
xcodebuild \
  -project OhMyMeme.xcodeproj \
  -scheme OhMyMeme \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="1" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_STYLE=Manual \
  build

APP="build/Build/Products/$CONFIGURATION-iphoneos/OhMyMeme.app"
if [ ! -d "$APP" ]; then
  echo "构建失败：未找到 $APP"
  exit 1
fi

echo "==> 打包 ipa"
rm -rf dist Payload
mkdir -p dist/Payload
cp -R "$APP" dist/Payload/
( cd dist && zip -qr "OhMyMeme-$VERSION.ipa" Payload )
rm -rf Payload

echo "==> 完成: dist/OhMyMeme-$VERSION.ipa"