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
ROOT_DIR="$(dirname "$SCRIPT_DIR")"  # 仓库根目录
LOG_FILE="$ROOT_DIR/build_log.txt"

# ===================== 日志系统 =====================
exec > >(tee -i "$LOG_FILE")
exec 2>&1

trap 'echo -e "${RED}❌ 构建失败，详见日志：$LOG_FILE${NC}"; gzip "$LOG_FILE"' ERR

# ===================== 基础配置 =====================
BUILD_TEMP="$ROOT_DIR/BuildTemp"
LIBS_OUTPUT="$ROOT_DIR/Frameworks"
RESOURCES_OUTPUT="$ROOT_DIR/Resources"
IPA_OUTPUT="$ROOT_DIR/IPA"

LDID_SOURCE_DIR="$ROOT_DIR/ldid"  # 本地源码目录
PATCH_FILE="$SCRIPT_DIR/ldid_combined_fix.patch" # 合并后的补丁

mkdir -p "$BUILD_TEMP" "$LIBS_OUTPUT" "$RESOURCES_OUTPUT" "$IPA_OUTPUT"

DEVICE_SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
if [ -z "$DEVICE_SDK_PATH" ]; then
  echo -e "${RED}❌ 未找到 iOS SDK 路径${NC}"; exit 1
fi

MIN_IOS_VERSION="12.0"
APP_NAME="PermanentStore"
VERSION="1.0"
CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
[ "$CPU_CORES" -gt 4 ] && CPU_CORES=4

# ===================== 全目录搜索关键文件 =====================
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

[ -z "$ENTITLEMENTS_FILE" ] && { echo -e "${RED}❌ 未找到 entitlements.plist${NC}"; exit 1; }
[ -z "$INFO_PLIST_FILE" ] && { echo -e "${RED}❌ 未找到 Info.plist${NC}"; exit 1; }

echo -e "${BLUE}🔍 找到文件：${NC}"
echo -e "${BLUE}  entitlements: $ENTITLEMENTS_FILE${NC}"
echo -e "${BLUE}  Info.plist: $INFO_PLIST_FILE${NC}"
echo -e "${BLUE}  Icon: $ICON_FILE${NC}"

# ===================== 环境检测 =====================
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  PermanentStore 完整构建（本地源码 + 合并补丁）${NC}"
echo -e "${BLUE}============================================================${NC}"

if ! command -v xcrun >/dev/null 2>&1; then
  echo -e "${RED}❌ 未检测到 Xcode 工具链${NC}"; exit 1
fi

echo -e "${YELLOW}🔧 校验 Autotools 依赖...${NC}"
if ! command -v libtoolize >/dev/null 2>&1; then
  brew install autoconf automake libtool pkg-config
fi

# ===================== 1. OpenSSL =====================
echo -e "\n${YELLOW}📦 [1/5] OpenSSL${NC}"
cd "$BUILD_TEMP" || exit 1
if [ ! -d openssl_install ]; then
    [ -d openssl ] || git clone --depth 1 https://github.com/openssl/openssl.git openssl
    cd openssl || exit 1
    ./Configure ios64-cross --prefix="$BUILD_TEMP/openssl_install" no-shared no-tests \
        -isysroot "$DEVICE_SDK_PATH" -mios-version-min="$MIN_IOS_VERSION"
    make -j"$CPU_CORES"
    make install_sw
    cd ..
fi
cp "$BUILD_TEMP/openssl_install/lib/libcrypto.a" "$LIBS_OUTPUT/" 2>/dev/null || true
cp "$BUILD_TEMP/openssl_install/lib/libssl.a" "$LIBS_OUTPUT/" 2>/dev/null || true
echo -e "${GREEN}✅ OpenSSL 静态库就绪${NC}"

# ===================== 2. libplist =====================
echo -e "\n${YELLOW}📦 [2/5] libplist${NC}"
cd "$BUILD_TEMP" || exit 1
if [ ! -d libplist_install ]; then
    [ -d libplist ] || git clone --depth 1 https://github.com/libimobiledevice/libplist.git libplist
    cd libplist || exit 1
    [ ! -f configure ] && ./autogen.sh
    ./configure --prefix="$BUILD_TEMP/libplist_install" --host=aarch64-apple-darwin \
        --enable-static --disable-shared --disable-tests \
        CC="xcrun -sdk iphoneos clang" CXX="xcrun -sdk iphoneos clang++" \
        CFLAGS="-arch arm64 -isysroot $DEVICE_SDK_PATH -mios-version-min=$MIN_IOS_VERSION" \
        CXXFLAGS="-arch arm64 -isysroot $DEVICE_SDK_PATH -mios-version-min=$MIN_IOS_VERSION"
    make -j"$CPU_CORES"
    make install
    cd ..
fi
cp "$BUILD_TEMP/libplist_install/lib/libplist-2.0.a" "$LIBS_OUTPUT/" 2>/dev/null || true
echo -e "${GREEN}✅ libplist 静态库就绪${NC}"

# ===================== 3. ldid（复制本地源码 + 应用合并补丁）=====================
echo -e "\n${YELLOW}📦 [3/5] ldid（本地源码编译）${NC}"

if [ ! -d "$LDID_SOURCE_DIR" ]; then
    echo -e "${RED}❌ 未找到本地 ldid 源码目录：$LDID_SOURCE_DIR${NC}"; exit 1
fi
if [ ! -f "$LDID_SOURCE_DIR/ldid.cpp" ]; then
    echo -e "${RED}❌ 在 $LDID_SOURCE_DIR 中未找到 ldid.cpp${NC}"; exit 1
fi

# 复制源码到构建目录
cd "$BUILD_TEMP" || exit 1
rm -rf ldid_build
mkdir -p ldid_build
echo -e "${BLUE}📋 复制源码从 $LDID_SOURCE_DIR 到 $BUILD_TEMP/ldid_build${NC}"
cp -r "$LDID_SOURCE_DIR/." "ldid_build/"
cd ldid_build || exit 1

# 应用合并补丁
if [ -f "$PATCH_FILE" ]; then
    echo -e "${BLUE}🔧 应用合并补丁...${NC}"
    patch -p1 < "$PATCH_FILE" || {
        echo -e "${RED}❌ 补丁应用失败（请检查 patch 文件）${NC}"
        exit 1
    }
else
    echo -e "${YELLOW}⚠️ 未找到补丁文件，跳过打补丁步骤${NC}"
fi

# 编译 ldid
echo -e "${BLUE}🛠️ 开始编译 ldid...${NC}"
xcrun -sdk iphoneos clang++ -std=c++14 \
    -arch arm64 \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="$MIN_IOS_VERSION" \
    -I"$BUILD_TEMP/openssl_install/include" \
    -I"$BUILD_TEMP/libplist_install/include" \
    -L"$BUILD_TEMP/openssl_install/lib" \
    -L"$BUILD_TEMP/libplist_install/lib" \
    -DHAVE_OPENSSL=1 \
    -DLDID_VERSION=\"v2.1.5\" \
    -o "$RESOURCES_OUTPUT/ldid" \
    ldid.cpp \
    -lcrypto -lssl \
    -framework Foundation -framework Security

echo -e "${GREEN}✅ ldid 编译完成${NC}"

# ===================== 4. zsign =====================
echo -e "\n${YELLOW}📦 [4/5] zsign${NC}"
cd "$BUILD_TEMP" || exit 1
[ -d zsign ] || git clone --depth 1 https://github.com/zhlynn/zsign.git zsign
cd zsign || exit 1

xcrun -sdk iphoneos clang++ -std=c++11 \
    -arch arm64 \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="$MIN_IOS_VERSION" \
    -I"$BUILD_TEMP/openssl_install/include" \
    -I"$BUILD_TEMP/libplist_install/include" \
    -L"$BUILD_TEMP/openssl_install/lib" \
    -L"$BUILD_TEMP/libplist_install/lib" \
    -lcrypto -lssl -lplist-2.0 \
    -o "$RESOURCES_OUTPUT/zsign" \
    *.cpp

echo -e "${GREEN}✅ zsign 编译完成${NC}"

# ===================== 5. Swift App =====================
echo -e "\n${YELLOW}📦 [5/5] Swift App${NC}"
SWIFT_FILES=$(find "$ROOT_DIR" -name "*.swift" ! -path "*/BuildTemp/*" 2>/dev/null)
if [ -z "$SWIFT_FILES" ]; then
  echo -e "${RED}❌ 未找到 Swift 文件${NC}"; exit 1
fi

APP_DIR="$BUILD_TEMP/Payload/$APP_NAME.app"
mkdir -p "$APP_DIR" || exit 1

xcrun -sdk iphoneos swiftc \
  -target arm64-apple-ios$MIN_IOS_VERSION \
  -sdk "$DEVICE_SDK_PATH" \
  -I "$BUILD_TEMP/openssl_install/include" \
  -I "$BUILD_TEMP/libplist_install/include" \
  -L "$LIBS_OUTPUT" \
  -lcrypto -lssl -lplist-2.0 \
  -framework Foundation \
  -framework UIKit \
  -framework UniformTypeIdentifiers \
  -o "$APP_DIR/$APP_NAME" \
  $SWIFT_FILES

cp "$RESOURCES_OUTPUT/ldid" "$APP_DIR/" 2>/dev/null || true
cp "$RESOURCES_OUTPUT/zsign" "$APP_DIR/" 2>/dev/null || true
chmod +x "$APP_DIR"/* 2>/dev/null || true

# ===================== 复制资源文件 =====================
cp "$INFO_PLIST_FILE" "$APP_DIR/Info.plist"
cp "$ENTITLEMENTS_FILE" "$APP_DIR/entitlements.plist"
if [ -n "$ICON_FILE" ]; then
    cp "$ICON_FILE" "$APP_DIR/Icon.png"
fi

# ===================== 签名 =====================
if [ -f "$APP_DIR/ldid" ]; then
  "$APP_DIR/ldid" -S"$APP_DIR/entitlements.plist" "$APP_DIR/$APP_NAME" 2>/dev/null || \
  echo -e "${YELLOW}⚠️ ldid 签名失败（无巨魔环境可忽略）${NC}"
fi

# ===================== 打包 IPA =====================
cd "$BUILD_TEMP" || exit 1
IPA_PATH="$IPA_OUTPUT/${APP_NAME}_${VERSION}.ipa"
zip -qr "$IPA_PATH" Payload

# ===================== 完成 =====================
echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}  构建完成 ✅${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "${BLUE}📦 静态库路径：$LIBS_OUTPUT${NC}"
echo -e "${BLUE}📦 IPA 路径：$IPA_PATH${NC}"
echo -e "${BLUE}📄 构建日志：$LOG_FILE${NC}"

gzip "$LOG_FILE"
