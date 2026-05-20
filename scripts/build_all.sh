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

mkdir -p "$BUILD_TEMP" "$LIBS_OUTPUT" "$RESOURCES_OUTPUT" "$IPA_OUTPUT"

DEVICE_SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
if [ -z "$DEVICE_SDK_PATH" ]; then
  echo -e "${RED}❌ 未找到 iOS SDK 路径（请安装 Xcode 命令行工具）${NC}"
  exit 1
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

if [ -z "$ENTITLEMENTS_FILE" ]; then
    echo -e "${RED}❌ 未找到 entitlements.plist${NC}"; exit 1
fi
if [ -z "$INFO_PLIST_FILE" ]; then
    echo -e "${RED}❌ 未找到 Info.plist${NC}"; exit 1
fi

echo -e "${BLUE}🔍 找到关键文件：${NC}"
echo -e "${BLUE}  entitlements: $ENTITLEMENTS_FILE${NC}"
echo -e "${BLUE}  Info.plist: $INFO_PLIST_FILE${NC}"
echo -e "${BLUE}  Icon: $ICON_FILE${NC}"

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  PermanentStore 完整构建（内置修复版）${NC}"
echo -e "${BLUE}============================================================${NC}"

# ===================== 环境检测 =====================
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
    ./Configure ios64-cross \
        --prefix="$BUILD_TEMP/openssl_install" \
        no-shared no-tests \
        -isysroot "$DEVICE_SDK_PATH" \
        -mios-version-min="$MIN_IOS_VERSION"
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
cp "$BUILD_TEMP/libplist_install/lib/libplist-2.0.a" "$LIBS_OUTPUT/" 2>/dev/null || true
echo -e "${GREEN}✅ libplist 静态库就绪${NC}"

# ===================== 3. ldid（复制源码 + SED 修复）=====================
echo -e "\n${YELLOW}📦 [3/5] ldid（iOS 目标编译）${NC}"

if [ ! -d "$LDID_SOURCE_DIR" ] || [ ! -f "$LDID_SOURCE_DIR/ldid.cpp" ]; then
    echo -e "${RED}❌ 未找到 ldid 源码目录或 ldid.cpp${NC}"; exit 1
fi

# 复制源码到构建目录
cd "$BUILD_TEMP" || exit 1
rm -rf ldid_build
mkdir -p ldid_build
echo -e "${BLUE}📋 复制源码从 $LDID_SOURCE_DIR${NC}"
cp -r "$LDID_SOURCE_DIR/." "ldid_build/"
cd ldid_build || exit 1

echo -e "${BLUE}🔧 使用 SED 修复源码兼容性...${NC}"

# 修复 1: 添加必要的 includes (如果还没有)
if ! grep -q "#include <memory>" ldid.cpp; then
    sed -i '' '1s/^/#include <memory>\n#include <vector>\n/' ldid.cpp
fi

# 修复 2: 替换 auto_ptr 为 unique_ptr
sed -i '' 's/std::auto_ptr/std::unique_ptr/g' ldid.cpp

# 修复 3: 替换 ASN1_STRING_data 为 OpenSSL 3.x 兼容函数
sed -i '' 's/ASN1_STRING_data(/ASN1_STRING_get0_data(/g' ldid.cpp

# 修复 4: 修复 VLA (变长数组) 为非标准的 vector
# 注意：这里假设原代码是 "char padding[size];"
sed -i '' 's/char padding$$size$$;/std::vector<char> padding(size, 0);/g' ldid.cpp
sed -i '' 's/memset(padding, 0, size);/\/\/ memset removed/g' ldid.cpp
sed -i '' 's/put(stream, padding, size);/put(stream, padding.data(), size);/g' ldid.cpp

# 修复 5: 修复 Algorithm 调用中的类型问题 (将 uint8_t hash[] 改为 vector)
sed -i '' 's/uint8_t hash$$algorithm\.size_$$;/std::vector<uint8_t> hash(algorithm.size_);/g' ldid.cpp
sed -i '' 's/memcmp(cdhash->hash, hash, algorithm.size_)/memcmp(cdhash->hash, hash.data(), algorithm.size_)/g' ldid.cpp

# 验证修复是否成功
if grep -q "std::auto_ptr" ldid.cpp; then
    echo -e "${RED}❌ auto_ptr 替换失败${NC}"; exit 1
fi
if grep -q "ASN1_STRING_data(" ldid.cpp; then
    echo -e "${RED}❌ ASN1_STRING_data 替换失败${NC}"; exit 1
fi

echo -e "${GREEN}✅ 源码修复完成${NC}"

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
