#!/bin/bash
set -euo pipefail  # 严格模式：未定义变量报错、命令失败退出、管道错误捕获

# ===================== 颜色定义 =====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ===================== 路径配置（修正为仓库根目录）=====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # scripts目录
ROOT_DIR="$(dirname "$SCRIPT_DIR")"                          # 仓库根目录（entitlements/Info.plist/Icon.png所在位置）
LOG_FILE="$ROOT_DIR/build_log.txt"                             # 日志输出到根目录

# ===================== 日志系统 =====================
exec > >(tee -i "$LOG_FILE")
exec 2>&1

trap 'echo -e "${RED}❌ 构建失败，详见日志：$LOG_FILE${NC}"; gzip "$LOG_FILE"' ERR

# ===================== 基础配置 =====================
BUILD_TEMP="$ROOT_DIR/BuildTemp"
LIBS_OUTPUT="$ROOT_DIR/Frameworks"
RESOURCES_OUTPUT="$ROOT_DIR/Resources"
IPA_OUTPUT="$ROOT_DIR/IPA"

mkdir -p "$BUILD_TEMP" "$LIBS_OUTPUT" "$RESOURCES_OUTPUT" "$IPA_OUTPUT"

# 获取 iOS SDK 路径（防空）
DEVICE_SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
if [ -z "$DEVICE_SDK_PATH" ]; then
  echo -e "${RED}❌ 未找到 iOS SDK 路径（请安装 Xcode 命令行工具）${NC}"
  exit 1
fi

MIN_IOS_VERSION="12.0"
APP_NAME="PermanentStore"
BUNDLE_ID="com.permanentstore.app"
VERSION="1.0"
BUILD_NUM="1"
CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
[ "$CPU_CORES" -gt 4 ] && CPU_CORES=4

# ===================== 全目录搜索关键文件（排除构建目录）=====================
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
    echo -e "${RED}❌ 未找到 entitlements.plist 文件（已搜索全目录）${NC}"
    exit 1
fi
if [ -z "$INFO_PLIST_FILE" ]; then
    echo -e "${RED}❌ 未找到 Info.plist 文件（已搜索全目录）${NC}"
    exit 1
fi
if [ -z "$ICON_FILE" ]; then
    echo -e "${YELLOW}⚠️ 未找到 Icon.png 文件（已搜索全目录）${NC}"
fi

echo -e "${BLUE}🔍 找到的关键文件：${NC}"
echo -e "${BLUE}  entitlements.plist: $ENTITLEMENTS_FILE${NC}"
echo -e "${BLUE}  Info.plist: $INFO_PLIST_FILE${NC}"
echo -e "${BLUE}  Icon.png: $ICON_FILE${NC}"

# ===================== 环境检测 =====================
echo -e "${BLUE}🔍 检测构建环境...${NC}"
if ! command -v xcrun >/dev/null 2>&1; then
  echo -e "${RED}❌ 未检测到 Xcode 工具链（请安装 Xcode 或命令行工具）${NC}"
  exit 1
fi

# ===================== 安装 Autotools（libplist 依赖）=====================
echo -e "${YELLOW}🔧 校验 Autotools 依赖...${NC}"
if ! command -v libtoolize >/dev/null 2>&1; then
  brew install autoconf automake libtool pkg-config
fi

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  PermanentStore 完整构建（含 ldid 源码修复）${NC}"
echo -e "${BLUE}  日志文件：$LOG_FILE${NC}"
echo -e "${BLUE}============================================================${NC}"

# ===================== 1. OpenSSL（静态库）=====================
echo -e "\n${YELLOW}📦 [1/5] OpenSSL${NC}"
cd "$BUILD_TEMP" || exit 1
[ -d openssl ] || git clone --depth 1 https://github.com/openssl/openssl.git openssl
cd openssl || exit 1
make clean >/dev/null 2>&1 || true
./Configure ios64-cross \
  --prefix="$BUILD_TEMP/openssl_install" \
  no-shared no-tests \
  -isysroot "$DEVICE_SDK_PATH" \
  -mios-version-min="$MIN_IOS_VERSION"
make -j"$CPU_CORES"
make install_sw
cp "$BUILD_TEMP/openssl_install/lib/libcrypto.a" "$LIBS_OUTPUT/"
cp "$BUILD_TEMP/openssl_install/lib/libssl.a" "$LIBS_OUTPUT/"
echo -e "${GREEN}✅ OpenSSL 静态库构建完成${NC}"

# ===================== 2. libplist（静态库）=====================
echo -e "\n${YELLOW}📦 [2/5] libplist${NC}"
cd "$BUILD_TEMP" || exit 1
[ -d libplist ] || git clone --depth 1 https://github.com/libimobiledevice/libplist.git libplist
cd libplist || exit 1
[ ! -f configure ] && ./autogen.sh
make clean >/dev/null 2>&1 || true
./configure \
  --prefix="$BUILD_TEMP/libplist_install" \
  --host=aarch64-apple-darwin \
  --enable-static \
  --disable-shared \
  --disable-tests \
  CC="xcrun -sdk iphoneos clang" \
  CXX="xcrun -sdk iphoneos clang++" \
  CFLAGS="-arch arm64 -isysroot $DEVICE_SDK_PATH -mios-version-min=$MIN_IOS_VERSION" \
  CXXFLAGS="-arch arm64 -isysroot $DEVICE_SDK_PATH -mios-version-min=$MIN_IOS_VERSION"
make -j"$CPU_CORES"
make install
cp "$BUILD_TEMP/libplist_install/lib/libplist-2.0.a" "$LIBS_OUTPUT/"
echo -e "${GREEN}✅ libplist 静态库构建完成${NC}"

# ===================== 3. ldid（iOS 目标编译 · 源码修复版）=====================
echo -e "\n${YELLOW}📦 [3/5] ldid（iOS 目标编译）${NC}"
cd "$BUILD_TEMP" || exit 1

LDID_REPO="https://github.com/ProcursusTeam/ldid.git"
CLONE_DIR="ldid"

# 克隆仓库（指定版本 v2.1.5）
rm -rf "$CLONE_DIR"
git clone --depth 1 --branch v2.1.5 "$LDID_REPO" "$CLONE_DIR" || {
  echo -e "${RED}❌ ldid 克隆失败${NC}"
  exit 1
}

cd "$CLONE_DIR" || exit 1

# ===================== 源码修复（替代补丁）=====================
echo -e "${BLUE}🔧 修复 ldid.cpp 源码（OpenSSL 兼容性）...${NC}"

# 1. 在文件开头添加 OpenSSL 兼容性头文件
sed -i '' '16a\
// OpenSSL 兼容性修复\
#define OPENSSL_API_COMPAT 0x10100000L\
#define OPENSSL_NO_DEPRECATED 0\
\
#include <openssl/conf.h>\
#include <openssl/asn1.h>\
#include <openssl/asn1t.h>\
#include <openssl/x509.h>\
#include <openssl/x509v3.h>\
#include <openssl/evp.h>\
' ldid.cpp

# 2. 修复 LDID_VERSION 定义（如果不存在）
grep -q "LDID_VERSION" ldid.cpp || sed -i '' 's/#include <openssl\/evp.h>/#include <openssl\/evp.h>\
#ifndef LDID_VERSION\
#define LDID_VERSION "2.1.5"\
#endif/' ldid.cpp

# 3. 修复类型转换问题（X509_NAME* 的 const 修饰）
sed -i '' 's/get(org, name, NID_organizationName)/get(org, const_cast<X509_NAME*>(name), NID_organizationName)/g' ldid.cpp
sed -i '' 's/get(common, name, NID_commonName)/get(common, const_cast<X509_NAME*>(name), NID_commonName)/g' ldid.cpp
sed -i '' 's/get(team, name, NID_organizationalUnitName)/get(team, const_cast<X509_NAME*>(name), NID_organizationalUnitName)/g' ldid.cpp

# 4. 修复 stream.sgetn 的类型转换
sed -i '' 's/stream.sgetn(reinterpret_cast<char *>(data), size)/stream.sgetn(reinterpret_cast<char *>(data), static_cast<std::streamsize>(size))/g' ldid.cpp

# 5. 修复 ASN1_STRING 长度处理
sed -i '' 's/_assert(ASN1_STRING_length(s) <= sizeof(identity->team) - 1)/int len = ASN1_STRING_length(s); _assert(len <= static_cast<int>(sizeof(identity->team) - 1))/g' ldid.cpp
sed -i '' 's/memcpy(identity->team, team, ASN1_STRING_length(s))/memcpy(identity->team, team, len)/g' ldid.cpp
sed -i '' 's/identity->team\[ASN1_STRING_length(s)\] = 0/identity->team\[len\] = 0/g' ldid.cpp

# 6. 修复 vector 类型匹配
sed -i '' 's/matches_.push_back(flag.first)/matches_.push_back(std::make_pair(flag.first.first, flag.first.second))/g' ldid.cpp

# 7. 修复 hash 数组定义
sed -i '' 's/uint8_t hash\[algorithm.size_\]/std::vector<uint8_t> hash(algorithm.size_)/g' ldid.cpp
sed -i '' 's/_assert(memcmp(cdhash->hash, hash, algorithm.size_) == 0)/_assert(memcmp(cdhash->hash, hash.data(), algorithm.size_) == 0)/g' ldid.cpp

# 验证修复是否生效
if ! grep -q "#include <openssl/x509v3.h>" ldid.cpp; then
  echo -e "${RED}❌ ldid 源码修复失败${NC}"
  exit 1
fi

# ===================== 编译 ldid =====================
clang++ -std=c++17 \
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

echo -e "${GREEN}✅ ldid（源码修复版）编译完成${NC}"

# ===================== 4. zsign（iOS 交叉编译）=====================
echo -e "\n${YELLOW}📦 [4/5] zsign${NC}"
cd "$BUILD_TEMP" || exit 1
[ -d zsign ] || git clone --depth 1 https://github.com/zhlynn/zsign.git zsign
cd zsign || exit 1

clang++ -std=c++11 \
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

# ===================== 5. Swift App（链接静态库）=====================
echo -e "\n${YELLOW}📦 [5/5] Swift App${NC}"
SWIFT_FILES=$(find "$ROOT_DIR" -name "*.swift" ! -path "*/BuildTemp/*" 2>/dev/null)
if [ -z "$SWIFT_FILES" ]; then
  echo -e "${RED}❌ 未找到 Swift 文件${NC}"
  exit 1
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

# 复制工具到 App 目录
cp "$RESOURCES_OUTPUT/ldid" "$APP_DIR/" 2>/dev/null || true
cp "$RESOURCES_OUTPUT/zsign" "$APP_DIR/" 2>/dev/null || true
chmod +x "$APP_DIR"/* 2>/dev/null || true

# ===================== 复制根目录找到的关键文件到 App =====================
# 复制 Info.plist（使用找到的路径）
cp "$INFO_PLIST_FILE" "$APP_DIR/Info.plist"

# 复制图标（使用找到的路径，若存在）
if [ -n "$ICON_FILE" ]; then
  cp "$ICON_FILE" "$APP_DIR/Icon.png"
  echo -e "${GREEN}✅ 图标文件已复制（$ICON_FILE）${NC}"
else
  echo -e "${YELLOW}⚠️ 未找到图标文件，App 将使用默认图标${NC}"
fi

# 复制 entitlements（使用找到的路径）
cp "$ENTITLEMENTS_FILE" "$APP_DIR/entitlements.plist"

# ===================== 签名（Ad-hoc，适配巨魔）=====================
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
