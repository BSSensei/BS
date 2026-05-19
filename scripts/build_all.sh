#!/bin/bash
set -euo pipefail  # 严格模式：未定义变量报错、命令失败退出、管道错误捕获

# ===================== 颜色 =====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ===================== 日志系统 =====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
LOG_FILE="$ROOT_DIR/build_log.txt"
exec > >(tee -i "$LOG_FILE")
exec 2>&1

trap 'echo -e "${RED}❌ 构建失败，详见日志：$LOG_FILE${NC}"; gzip "$LOG_FILE"' ERR

# ===================== 基础配置（防空变量）=====================
BUILD_TEMP="${ROOT_DIR}/BuildTemp"
LIBS_OUTPUT="${ROOT_DIR}/Frameworks"
RESOURCES_OUTPUT="${ROOT_DIR}/Resources"
IPA_OUTPUT="${ROOT_DIR}/IPA"

# 检查关键目录是否存在
mkdir -p "$BUILD_TEMP" "$LIBS_OUTPUT" "$RESOURCES_OUTPUT" "$IPA_OUTPUT" || {
  echo -e "${RED}❌ 无法创建构建目录${NC}"
  exit 1
}

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

# ===================== Entitlements =====================
ENTITLEMENTS_FILE="$ROOT_DIR/entitlements.plist"
if [ ! -f "$ENTITLEMENTS_FILE" ]; then
  echo -e "${YELLOW}⚠️ 未找到自定义 entitlements.plist，使用默认配置${NC}"
  cat > "$ENTITLEMENTS_FILE" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>platform-application</key>
    <true/>
    <key>com.apple.private.skip-library-validation</key>
    <true/>
    <key>com.apple.private.security.no-container</key>
    <true/>
</dict>
</plist>
EOF
fi

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
echo -e "${BLUE}  PermanentStore 完整构建（日志已启用）${NC}"
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

# ===================== 3. ldid（iOS 交叉编译）=====================
echo -e "\n${YELLOW}📦 [3/5] ldid（iOS 目标编译）${NC}"
cd "$BUILD_TEMP" || exit 1

LDID_REPO="https://github.com/ProcursusTeam/ldid.git"
CLONE_DIR="ldid"

rm -rf "$CLONE_DIR"
git clone --depth 1 "$LDID_REPO" "$CLONE_DIR" || {
  echo -e "${RED}❌ ldid 克隆失败${NC}"
  exit 1
}

cd "$CLONE_DIR" || exit 1

# 检查源文件是否存在
if [ ! -f "ldid.cpp" ]; then
  echo -e "${RED}❌ 未找到 ldid.cpp 源文件${NC}"
  exit 1
fi

# 检查 libplist 头文件是否存在
if [ ! -f "$BUILD_TEMP/libplist_install/include/plist/plist.h" ]; then
  echo -e "${RED}❌ 未找到 plist/plist.h 头文件${NC}"
  exit 1
fi

# 编译 ldid（修复头文件路径和库链接）
clang++ -std=c++17 \
  -arch arm64 \
  -isysroot "$DEVICE_SDK_PATH" \
  -mios-version-min="$MIN_IOS_VERSION" \
  -I"$BUILD_TEMP/openssl_install/include" \
  -I"$BUILD_TEMP/libplist_install/include" \
  -L"$BUILD_TEMP/openssl_install/lib" \
  -L"$BUILD_TEMP/libplist_install/lib" \
  -lcrypto \
  -lplist-2.0 \
  -o "$RESOURCES_OUTPUT/ldid" \
  ldid.cpp

echo -e "${GREEN}✅ ldid（iOS 版）编译完成${NC}"

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

# ===================== Info.plist =====================
cat > "$APP_DIR/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>PermanentStore</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUM</string>
    <key>LSRequiresIPhoneOS</key><true/>
    <key>MinimumOSVersion</key><string>$MIN_IOS_VERSION</string>
</dict>
</plist>
EOF

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
