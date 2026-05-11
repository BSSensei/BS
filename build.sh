#!/bin/bash
set -e

# ============================================
#  PermanentStore 编译打包脚本
# ============================================

PROJECT_NAME="PermanentStore"
SCHEME_NAME="PermanentStore"
CONFIGURATION="Release"
OUTPUT_DIR="$(pwd)/build"
APP_NAME="${PROJECT_NAME}.app"
IPA_NAME="${PROJECT_NAME}.ipa"
TIPA_NAME="${PROJECT_NAME}.tipa"

echo "🧹 清理旧构建..."
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# 检查静态库是否存在
if [ ! -d "Frameworks/lib" ]; then
    echo "⚠️  Frameworks/lib 不存在，尝试编译静态库..."
    if [ -f "scripts/build_all.sh" ]; then
        bash scripts/build_all.sh
    else
        echo "❌ 找不到编译脚本，请先运行 GitHub Actions 或将 Frameworks/ 放入项目"
        exit 1
    fi
fi

echo "📦 编译 ${PROJECT_NAME}..."

# 编译
xcodebuild \
    -project "${PROJECT_NAME}.xcodeproj" \
    -scheme "${SCHEME_NAME}" \
    -configuration "${CONFIGURATION}" \
    -sdk iphoneos \
    -archivePath "${OUTPUT_DIR}/${PROJECT_NAME}.xcarchive" \
    archive \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=NO

# 提取 .app
APP_PATH="${OUTPUT_DIR}/${PROJECT_NAME}.xcarchive/Products/Applications/${APP_NAME}"
cp -R "$APP_PATH" "${OUTPUT_DIR}/${APP_NAME}"

echo "✅ App 编译完成: ${OUTPUT_DIR}/${APP_NAME}"

# 伪签名（如果 ldid 可用）
if command -v ldid &> /dev/null; then
    if [ -f "entitlements.plist" ]; then
        echo "🔐 使用 entitlements 伪签名..."
        ldid -Sentitlements.plist "${OUTPUT_DIR}/${APP_NAME}/${PROJECT_NAME}"
    else
        echo "🔐 伪签名（无 entitlements）..."
        ldid -S "${OUTPUT_DIR}/${APP_NAME}/${PROJECT_NAME}"
    fi
    
    # 签名 Frameworks
    if [ -d "${OUTPUT_DIR}/${APP_NAME}/Frameworks" ]; then
        for lib in "${OUTPUT_DIR}/${APP_NAME}/Frameworks/"*.dylib; do
            [ -f "$lib" ] && ldid -S "$lib" && echo "  签名: $(basename $lib)"
        done
    fi
else
    echo "⚠️  ldid 未安装，跳过签名"
fi

# 打包 IPA
echo "📦 打包 IPA..."
cd "$OUTPUT_DIR"
mkdir -p Payload
cp -R "$APP_NAME" Payload/
zip -qr "$IPA_NAME" Payload
rm -rf Payload

# 打包 TIPA（巨魔格式）
echo "📦 打包 TIPA..."
tar -cf "$TIPA_NAME" "$APP_NAME"

# 清理
rm -rf "${PROJECT_NAME}.xcarchive"

echo ""
echo "════════════════════════════════"
echo "✅ 构建完成！"
echo "════════════════════════════════"
echo "  IPA:  ${OUTPUT_DIR}/${IPA_NAME}"
echo "  TIPA: ${OUTPUT_DIR}/${TIPA_NAME}"
echo "  App:  ${OUTPUT_DIR}/${APP_NAME}"
