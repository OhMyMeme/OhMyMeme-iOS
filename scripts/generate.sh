#!/usr/bin/env bash
# 生成 Xcode 工程（首次在 Mac 上运行，或修改 project.yml 后运行）
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen 未安装，请先执行: brew install xcodegen"
  exit 1
fi

xcodegen generate
echo "已生成 OhMyMeme.xcodeproj"