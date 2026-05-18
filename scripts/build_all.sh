#!/bin/bash
set -e

# ===================== 颜色 =====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ===================== 日志系统 =====================
LOG_FILE="$ROOT_DIR/build_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -i "$LOG_FILE")
exec 2>&1

trap 'echo -e "${RED}❌ 构建失败，详见日志：$LOG_FILE${NC}"' ERR

# ===================== 基础配置 =====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

BUILD_TEMP="$ROOT_DIR/BuildTemp"
LIBS_OUTPUT="$ROOT_DIR/Libraries"
RESOURCES_OUTPUT="$ROOT_DIR/Resources"
IPA_OUTPUT="$ROOT_DIR/IPA"

mkdir -p "$BUILD_TEMP" "$LIBS_OUTPUT" "$RESOURCES_OUTPUT" "$IPA_OUTPUT"

DEVICE_SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
MIN_IOS_VERSION="12.0"
APP_NAME="PermanentStore"
BUNDLE_ID="com.permanentstore.app"
VERSION="1.0"
BUILD_NUM="1"
CPU_CORES=$(sysctl -n hw.ncpu)
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
else
    echo -e "${GREEN}✅ 使用自定义 entitlements.plist：$ENTITLEMENTS_FILE${NC}"
fi

# ===================== 环境检测 =====================
echo -e "${BLUE}🔍 检测构建环境...${NC}"
if ! xcrun --version >/dev/null 2>&1; then
    echo -e "${RED}❌ 未检测到 Xcode 工具链${NC}"
    exit 1
fi

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  PermanentStore 构建（日志已启用）${NC}"
echo -e "${BLUE}  日志文件：$LOG_FILE${NC}"
echo -e "${BLUE}============================================================${NC}"

# ===================== 1. OpenSSL =====================
echo -e "\n${YELLOW}📦 [1/5] OpenSSL${NC}"
cd "$BUILD_TEMP"
[ -d openssl ] || git clone --depth 1 https://github.com/openssl/openssl.git openssl
cd openssl
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
echo -e "${GREEN}✅ OpenSSL${NC}"

# ===================== 2. libplist =====================
echo -e "\n${YELLOW}📦 [2/5] libplist${NC}"
cd "$BUILD_TEMP"
[ -d libplist ] || git clone --depth 1 https://github.com/libimobiledevice/libplist.git libplist
cd libplist
[ ! -f configure ] && ./autogen.sh
make clean >/dev/null 2>&1 || true
./configure \
    --prefix="$BUILD_TEMP/libplist_install" \
    --host=aarch64-apple-darwin \
    --enable-static --disable-shared \
    --disable-tests \
    CC="xcrun -sdk iphoneos clang" \
    CXX="xcrun -sdk iphoneos clang++" \
    CFLAGS="-arch arm64 -isysroot $DEVICE_SDK_PATH -mios-version-min=$MIN_IOS_VERSION" \
    CXXFLAGS="-arch arm64 -isysroot $DEVICE_SDK_PATH -mios-version-min=$MIN_IOS_VERSION"
make -j"$CPU_CORES"
make install
cp "$BUILD_TEMP/libplist_install/lib/libplist-2.0.a" "$LIBS_OUTPUT/"
echo -e "${GREEN}✅ libplist${NC}"

# ===================== 3. ldid2 =====================
echo -e "\n${YELLOW}📦 [3/5] ldid2${NC}"
cd "$BUILD_TEMP"
[ -d ldid2 ] || git clone https://github.com/ProcursusTeam/ldid2.git ldid2
cd ldid2
clang++ -std=c++17 \
    -arch arm64 \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="$MIN_IOS_VERSION" \
    -I"$BUILD_TEMP/openssl_install/include" \
    -L"$BUILD_TEMP/openssl_install/lib" \
    -lcrypto \
    -o "$RESOURCES_OUTPUT/ldid2" \
    ldid2.cpp
echo -e "${GREEN}✅ ldid2${NC}"

# ===================== 4. zsign =====================
echo -e "\n${YELLOW}📦 [4/5] zsign${NC}"
cd "$BUILD_TEMP"
[ -d zsign ] || git clone https://github.com/JayBrown/zsign.git zsign
cd zsign
clang++ -std=c++11 \
    -arch arm64 \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="$MIN_IOS_VERSION" \
    -I"$BUILD_TEMP/openssl_install/include" \
    -L"$BUILD_TEMP/openssl_install/lib" \
    -lcrypto -lssl \
    -o "$RESOURCES_OUTPUT/zsign" \
    *.cpp
echo -e "${GREEN}✅ zsign${NC}"

# ===================== 5. Swift App =====================
echo -e "\n${YELLOW}📱 [5/5] Swift App${NC}"
SWIFT_FILES=$(find "$ROOT_DIR" -name "*.swift" ! -path "*/BuildTemp/*")
[ -z "$SWIFT_FILES" ] && echo -e "${RED}❌ 未找到 Swift 文件${NC}" && exit 1

APP_DIR="$BUILD_TEMP/Payload/$APP_NAME.app"
mkdir -p "$APP_DIR"

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

cp "$RESOURCES_OUTPUT/ldid2" "$APP_DIR/" 2>/dev/null || true
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

# ===================== 签名 =====================
if [ -f "$APP_DIR/ldid2" ]; then
    "$APP_DIR/ldid2" -S"$APP_DIR/entitlements.plist" "$APP_DIR/$APP_NAME" 2>/dev/null || \
    echo -e "${YELLOW}⚠️ ldid2 签名失败（无巨魔环境可忽略）${NC}"
fi

cd "$BUILD_TEMP"
IPA_PATH="$IPA_OUTPUT/${APP_NAME}_${VERSION}.ipa"
zip -qr "$IPA_PATH" Payload

# ===================== 完成 =====================
echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}  构建完成 ✅${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "${BLUE}📦 IPA 文件：$IPA_PATH${NC}"
echo -e "${BLUE}📄 构建日志：$LOG_FILE${NC}"
echo -e "${YELLOW}💡 可直接下载日志文件查看详细构建过程${NC}"
