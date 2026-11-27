#!/bin/bash
# CcClean V1.0 发布流水线（基线 14.2：archive → export → codesign → DMG → notarytool → stapler → spctl）
# 用法：./scripts/release.sh <版本号> [开发者团队ID]
# 前置：Xcode 已登录 Apple ID（notarytool credentials），签名证书与 provisioning 就绪。
set -euo pipefail

VERSION="${1:?用法: release.sh <版本号> [团队ID]}"
TEAM_ID="${2:-}"
APP_NAME="CcClean"
SCHEME="CcCleanApp"
BUILD_DIR=".build/release-pipeline"
ENTITLEMENTS="Shared/Entitlements/CcCleanApp.entitlements"

echo "=== ① 构建（xcarchive）==="
xcodebuild -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" archive \
    CURRENT_PROJECT_VERSION="$VERSION" MARKETING_VERSION="$VERSION" \
    CODE_SIGN_IDENTITY="Apple Development"

echo "=== ② 导出 .app 并验证签名 ===="
APP_PATH=$(find "$BUILD_DIR/$APP_NAME.xcarchive/Products/Applications" -name "$APP_NAME.app" -maxdepth 1)
codesign --verify --strict --verbose=2 "$APP_PATH"
codesign -dv --entitlements - "$APP_PATH" | tee "$BUILD_DIR/entitlements-snapshot.txt"

echo "=== ③ Gatekeeper 评估（未公证前预期失败，记录基线）==="
spctl -a -vv "$APP_PATH" || true

echo "=== ④ 打包 DMG ===="
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$APP_PATH" \
    -ov -format UDZO "$DMG_PATH"

echo "=== ⑤ 公证（notarytool submit + wait）==="
if [ -n "$TEAM_ID" ]; then
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "cclean-notary" --wait \
        || { echo "公证提交失败（检查 keychain-profile 'cclean-notary'）"; exit 1; }
    echo "=== ⑥ 装订票据（stapler）==="
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    echo "=== ⑦ 重新打包 DMG（含装订票据）==="
    rm -f "$DMG_PATH"
    hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$APP_PATH" \
        -ov -format UDZO "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
else
    echo "（未提供团队 ID，跳过公证——本地构建仅供回归测试）"
fi

echo "=== ⑧ 最终 Gatekeeper 验证 ===="
spctl -a -vv "$APP_PATH" && echo "✅ spctl 通过" || echo "❌ spctl 未通过（未公证或被拒）"

echo "=== ⑨ 干净用户安装冒烟（提示人工执行）==="
cat <<EOF
请在新用户环境执行以下冒烟检查（基线 14.6）：
  1. 双击 DMG 拖入 /Applications，启动无崩溃
  2. 设置页显示 6 项能力状态
  3. 应用清单扫描出本机应用（首屏 < 300ms）
  4. 系统垃圾页只读预览不触发任何删除
  5. 卸载一个测试应用 → 撤销 → 文件恢复
  6. Helper 未注册时系统级灰显 + 引导可见
EOF

echo "✅ 发布流水线完成: $DMG_PATH"