#!/bin/bash
set -euo pipefail

# ===================== 颜色定义 =====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ===================== 路径配置 =====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="$ROOT_DIR/build_log.txt"

# ===================== 日志系统 =====================
exec > >(tee -i "$LOG_FILE")
exec 2>&1

trap 'echo -e "${RED}❌ 构建失败，详见日志：$LOG_FILE${NC}"; gzip "$LOG_FILE" 2>/dev/null || true' ERR

# ===================== 基础配置 =====================
BUILD_TEMP="$ROOT_DIR/BuildTemp"
LIBS_OUTPUT="$ROOT_DIR/Frameworks"
RESOURCES_OUTPUT="$ROOT_DIR/Resources"
IPA_OUTPUT="$ROOT_DIR/IPA"
LDID_SOURCE_DIR="$ROOT_DIR/ldid"

mkdir -p "$BUILD_TEMP" "$LIBS_OUTPUT" "$RESOURCES_OUTPUT" "$IPA_OUTPUT"

DEVICE_SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
if [ -z "$DEVICE_SDK_PATH" ]; then
  echo -e "${RED}❌ 未找到 iOS SDK 路径${NC}"
  exit 1
fi

MIN_IOS_VERSION="12.0"
APP_NAME="PermanentStore"
VERSION="1.0"
CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
[ "$CPU_CORES" -gt 4 ] && CPU_CORES=4

# ===================== 搜索关键文件 =====================
search_file() {
    local filename="$1"
    find "$ROOT_DIR" -type f -name "$filename" \
        ! -path "*/BuildTemp/*" \
        ! -path "*/.git/*" \
        ! -path "*/IPA/*" \
        ! -path "*/Frameworks/*" | head -1
}

ENTITLEMENTS_FILE=$(search_file "entitlements.plist")
INFO_PLIST_FILE=$(search_file "Info.plist")
ICON_FILE=$(search_file "Icon.png")

if [ -z "$ENTITLEMENTS_FILE" ] || [ -z "$INFO_PLIST_FILE" ]; then
    echo -e "${RED}❌ 未找到必要的配置文件${NC}"; exit 1
fi

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  PermanentStore 完整构建（仅 ldid）${NC}"
echo -e "${BLUE}============================================================${NC}"

# ===================== 1. OpenSSL =====================
echo -e "\n${YELLOW}📦 [1/4] OpenSSL${NC}"
cd "$BUILD_TEMP" || exit 1
if [ ! -d openssl_install ]; then
    [ -d openssl ] || git clone --depth 1 https://github.com/openssl/openssl.git openssl
    cd openssl || exit 1
    ./Configure ios64-cross \
        --prefix="$BUILD_TEMP/openssl_install" \
        no-shared no-tests \
        -isysroot "$DEVICE_SDK_PATH" \
        -mios-version-min="$MIN_IOS_VERSION"
    make -j"$CPU_CORES"
    make install_sw
    cd ..
fi
echo -e "${GREEN}✅ OpenSSL 完成${NC}"

# ===================== 2. libplist =====================
echo -e "\n${YELLOW}📦 [2/4] libplist${NC}"
cd "$BUILD_TEMP" || exit 1
if [ ! -d libplist_install ]; then
    [ -d libplist ] || git clone --depth 1 https://github.com/libimobiledevice/libplist.git libplist
    cd libplist || exit 1
    [ ! -f configure ] && ./autogen.sh
    ./configure \
        --prefix="$BUILD_TEMP/libplist_install" \
        --host=aarch64-apple-darwin \
        --enable-static --disable-shared --disable-tests \
        CC="xcrun -sdk iphoneos clang" \
        CXX="xcrun -sdk iphoneos clang++" \
        CFLAGS="-arch arm64 -isysroot $DEVICE_SDK_PATH -mios-version-min=$MIN_IOS_VERSION" \
        CXXFLAGS="-arch arm64 -isysroot $DEVICE_SDK_PATH -mios-version-min=$MIN_IOS_VERSION"
    make -j"$CPU_CORES"
    make install
    cd ..
fi
echo -e "${GREEN}✅ libplist 完成${NC}"

# ===================== 3. ldid =====================
echo -e "\n${YELLOW}📦 [3/4] ldid${NC}"

if [ ! -d "$LDID_SOURCE_DIR" ] || [ ! -f "$LDID_SOURCE_DIR/ldid.cpp" ]; then
    echo -e "${RED}❌ 未找到 ldid 源码${NC}"; exit 1
fi

cd "$BUILD_TEMP" || exit 1
rm -rf ldid_build
mkdir -p ldid_build

# 复制 ldid 源码目录下所有文件（包括 ldid.hpp 和其他依赖文件）
cp -r "$LDID_SOURCE_DIR/." ldid_build/

cd ldid_build || exit 1

# 从 scripts 目录复制并应用补丁文件
PATCH_FILE="$SCRIPT_DIR/ldid_complete.patch"
if [ -f "$PATCH_FILE" ]; then
    echo -e "${BLUE}🔧 应用补丁...${NC}"
    git apply "$PATCH_FILE" 2>/dev/null || patch -p1 < "$PATCH_FILE" 2>/dev/null || patch ldid.cpp < "$PATCH_FILE" 2>/dev/null || true
    echo -e "${GREEN}✅ 补丁应用完成${NC}"
else
    echo -e "${YELLOW}⚠️ 未找到补丁文件: $PATCH_FILE，跳过${NC}"
fi

# 编译
echo -e "${BLUE}🛠️ 编译 ldid...${NC}"
xcrun -sdk iphoneos clang++ -std=c++14 \
    -arch arm64 \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="$MIN_IOS_VERSION" \
    -I"$BUILD_TEMP/openssl_install/include" \
    -I"$BUILD_TEMP/libplist_install/include" \
    -I. \
    -L"$BUILD_TEMP/openssl_install/lib" \
    -L"$BUILD_TEMP/libplist_install/lib" \
    -DHAVE_OPENSSL=1 \
    -o "$RESOURCES_OUTPUT/ldid" \
    ldid.cpp \
    "$BUILD_TEMP/openssl_install/lib/libcrypto.a" \
    "$BUILD_TEMP/libplist_install/lib/libplist-2.0.a" \
    -framework Foundation -framework Security

if [ -f "$RESOURCES_OUTPUT/ldid" ]; then
    echo -e "${GREEN}✅ ldid 编译成功${NC}"
else
    echo -e "${RED}❌ ldid 编译失败${NC}"
    exit 1
fi

# ===================== 4. Swift App =====================
echo -e "\n${YELLOW}📦 [4/4] Swift App${NC}"

SWIFT_FILES=$(find "$ROOT_DIR" -name "*.swift" ! -path "*/BuildTemp/*" 2>/dev/null)
if [ -z "$SWIFT_FILES" ]; then
    echo -e "${RED}❌ 未找到 Swift 文件${NC}"
    exit 1
fi

APP_DIR="$BUILD_TEMP/Payload/$APP_NAME.app"
mkdir -p "$APP_DIR"

echo -e "${BLUE}🔨 编译 Swift...${NC}"
xcrun -sdk iphoneos swiftc \
    -target arm64-apple-ios$MIN_IOS_VERSION \
    -sdk "$DEVICE_SDK_PATH" \
    -O \
    -framework Foundation UIKit UniformTypeIdentifiers \
    -o "$APP_DIR/$APP_NAME" \
    $SWIFT_FILES

# 复制资源和工具
cp "$INFO_PLIST_FILE" "$APP_DIR/Info.plist"
cp "$ENTITLEMENTS_FILE" "$APP_DIR/entitlements.plist"
[ -n "$ICON_FILE" ] && cp "$ICON_FILE" "$APP_DIR/Icon.png"
cp "$RESOURCES_OUTPUT/ldid" "$APP_DIR/"
chmod +x "$APP_DIR/ldid" 2>/dev/null || true

# ===================== 打包 IPA =====================
cd "$BUILD_TEMP" || exit 1
IPA_PATH="$IPA_OUTPUT/${APP_NAME}_${VERSION}.ipa"
zip -qr "$IPA_PATH" Payload

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}  构建完成 ✅${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "${BLUE}📦 IPA 路径：$IPA_PATH${NC}"
echo -e "${BLUE}📄 构建日志：$LOG_FILE${NC}"

gzip -f "$LOG_FILE" 2>/dev/null || true
