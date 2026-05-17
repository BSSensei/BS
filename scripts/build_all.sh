#!/bin/bash
set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

trap 'echo -e "${RED}❌ 构建失败，退出码: $?${NC}"' ERR

# ============================================================
# 配置
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
BUILD_TEMP="$ROOT_DIR/BuildTemp"
LIBS_OUTPUT="$ROOT_DIR/Libraries"
RESOURCES_OUTPUT="$ROOT_DIR/Resources"
IPA_OUTPUT="$ROOT_DIR/IPA"
ENTITLEMENTS_FILE="$ROOT_DIR/entitlements.plist"

mkdir -p "$BUILD_TEMP" "$LIBS_OUTPUT" "$RESOURCES_OUTPUT" "$IPA_OUTPUT"

DEVICE_SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
MIN_IOS_VERSION="12.0"
APP_NAME="PermanentStore"
BUNDLE_ID="com.permanentstore.app"
VERSION="1.0"
BUILD_NUM="1"
CPU_CORES=$(sysctl -n hw.ncpu)
[ "$CPU_CORES" -gt 4 ] && CPU_CORES=4

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  PermanentStore 静态库构建脚本${NC}"
echo -e "${BLUE}  （支持巨魔商店 + 开发者证书）${NC}"
echo -e "${BLUE}============================================================${NC}"

# 默认 entitlements
if [ ! -f "$ENTITLEMENTS_FILE" ]; then
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

# ============================================================
# 1. OpenSSL 静态库
# ============================================================
echo -e "\n${YELLOW}📦 [1/5] 编译 OpenSSL 静态库${NC}"
cd "$BUILD_TEMP"
if [ ! -d "openssl_src" ]; then
    git clone --depth 1 https://github.com/openssl/openssl.git openssl_src
fi
cd openssl_src
make clean 2>/dev/null || true
make distclean 2>/dev/null || true
./Configure ios64-cross \
    --prefix="$BUILD_TEMP/openssl_install" \
    no-shared no-tests \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="${MIN_IOS_VERSION}"
make -j"${CPU_CORES}"
make install_sw
cp "$BUILD_TEMP/openssl_install/lib/libcrypto.a" "$LIBS_OUTPUT/"
cp "$BUILD_TEMP/openssl_install/lib/libssl.a" "$LIBS_OUTPUT/"
echo -e "${GREEN}  ✅ OpenSSL 静态库${NC}"

# ============================================================
# 2. libplist 静态库
# ============================================================
echo -e "\n${YELLOW}📦 [2/5] 编译 libplist 静态库${NC}"
if ! command -v libtoolize &> /dev/null; then
    brew install autoconf automake libtool
fi
cd "$BUILD_TEMP"
if [ ! -d "libplist_src" ]; then
    git clone --depth 1 https://github.com/libimobiledevice/libplist.git libplist_src
fi
cd libplist_src
if [ ! -f "./configure" ]; then
    ./autogen.sh
fi
make clean 2>/dev/null || true
make distclean 2>/dev/null || true
export CC="xcrun -sdk iphoneos clang -arch arm64"
export CXX="xcrun -sdk iphoneos clang++ -arch arm64"
export CFLAGS="-arch arm64 -isysroot $DEVICE_SDK_PATH -mios-version-min=${MIN_IOS_VERSION}"
export CXXFLAGS="-arch arm64 -isysroot $DEVICE_SDK_PATH -mios-version-min=${MIN_IOS_VERSION}"
export LDFLAGS="-arch arm64 -isysroot $DEVICE_SDK_PATH -mios-version-min=${MIN_IOS_VERSION}"
./configure \
    --prefix="$BUILD_TEMP/libplist_install" \
    --enable-static --disable-shared --disable-tests \
    --host=arm64-apple-darwin
make -j"${CPU_CORES}"
make install
cp "$BUILD_TEMP/libplist_install/lib/libplist-2.0.a" "$LIBS_OUTPUT/"
echo -e "${GREEN}  ✅ libplist 静态库${NC}"

# ============================================================
# 3. ldid2（支持 p12 开发者证书签名）
# ============================================================
echo -e "\n${YELLOW}📦 [3/5] 编译 ldid2 (支持开发者证书)${NC}"
cd "$BUILD_TEMP"
if [ ! -d "ldid2_src" ]; then
    git clone https://github.com/ProcursusTeam/ldid2.git ldid2_src
fi
cd ldid2_src
cat > openssl_fix.h << 'EOF'
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/asn1.h>
#include <openssl/bio.h>
#include <openssl/pem.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pkcs12.h>
EOF
if ! grep -q "openssl_fix.h" ldid2.cpp; then
    sed -i '' '1i\
#include "openssl_fix.h"
' ldid2.cpp
fi
# 编译可执行文件
xcrun -sdk iphoneos clang++ \
    -arch arm64 -std=c++17 \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="${MIN_IOS_VERSION}" \
    -I"$BUILD_TEMP/openssl_install/include" -I. \
    -L"$BUILD_TEMP/openssl_install/lib" \
    -lcrypto \
    -o "$RESOURCES_OUTPUT/ldid2" ldid2.cpp
# 生成静态库
OBJECTS_LDID=""
for src in *.cpp; do
    obj=$(basename "$src" .cpp).o
    xcrun -sdk iphoneos clang++ -arch arm64 -std=c++17 -fPIC \
        -isysroot "$DEVICE_SDK_PATH" \
        -mios-version-min="${MIN_IOS_VERSION}" \
        -I"$BUILD_TEMP/openssl_install/include" -I. \
        -c "$src" -o "$obj"
    OBJECTS_LDID="$OBJECTS_LDID $obj"
done
xcrun -sdk iphoneos ar rcs "$LIBS_OUTPUT/libldid2.a" $OBJECTS_LDID
echo -e "${GREEN}  ✅ ldid2 静态库 + 可执行文件${NC}"

# ============================================================
# 4. zsign（也支持开发者证书，与 ldid2 功能重叠，可选）
# ============================================================
echo -e "\n${YELLOW}📦 [4/5] 编译 zsign (可选开发者证书签名工具)${NC}"
cd "$BUILD_TEMP"
if [ ! -d "zsign_src" ]; then
    git clone https://github.com/JayBrown/zsign.git zsign_src
fi
cd zsign_src
# 创建统一修复头文件
cat > openssl_fix.h << 'EOF'
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/asn1.h>
#include <openssl/bio.h>
#include <openssl/pem.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pkcs12.h>
#include <openssl/rand.h>
EOF
# 修复所有 cpp 文件
for file in *.cpp; do
    if ! grep -q "openssl_fix.h" "$file"; then
        sed -i '' '1i\
#include "openssl_fix.h"
' "$file"
    fi
    sed -i '' 's/X509_NAME \*nm = X509_get_subject_name/const X509_NAME *nm = X509_get_subject_name/g' "$file"
    sed -i '' 's/X509_NAME \*nm = X509_get_issuer_name/const X509_NAME *nm = X509_get_issuer_name/g' "$file"
    sed -i '' 's/ASN1_STRING \*s/const ASN1_STRING *s/g' "$file"
done
# 编译静态库
OBJECTS_Z=""
for src in *.cpp; do
    obj=$(basename "$src" .cpp).o
    xcrun -sdk iphoneos clang++ -arch arm64 -std=c++11 -fPIC \
        -isysroot "$DEVICE_SDK_PATH" \
        -mios-version-min="${MIN_IOS_VERSION}" \
        -I"$BUILD_TEMP/openssl_install/include" -I. \
        -c "$src" -o "$obj"
    OBJECTS_Z="$OBJECTS_Z $obj"
done
xcrun -sdk iphoneos ar rcs "$LIBS_OUTPUT/libzsign.a" $OBJECTS_Z
# 编译可执行文件
xcrun -sdk iphoneos clang++ \
    -arch arm64 -std=c++11 \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="${MIN_IOS_VERSION}" \
    -I"$BUILD_TEMP/openssl_install/include" -I. \
    -L"$BUILD_TEMP/openssl_install/lib" \
    -lcrypto -lssl \
    -o "$RESOURCES_OUTPUT/zsign" *.cpp
echo -e "${GREEN}  ✅ zsign 静态库 + 可执行文件${NC}"

# ============================================================
# 5. 编译 Swift 代码并打包 IPA
# ============================================================
echo -e "\n${YELLOW}📱 [5/5] 编译 Swift IPA${NC}"
SWIFT_SOURCES=$(find "$ROOT_DIR" -name "*.swift" -type f 2>/dev/null | grep -v "BuildTemp" | grep -v "Libraries" | grep -v "Resources" | grep -v "IPA" | tr '\n' ' ')
if [ -z "$SWIFT_SOURCES" ]; then
    echo -e "${RED}❌ 未找到 Swift 源文件${NC}"
    exit 1
fi
OBJECTS_SWIFT=""
for src in $SWIFT_SOURCES; do
    obj_name=$(basename "$src" .swift).o
    echo "  编译: $(basename "$src")"
    xcrun -sdk iphoneos swiftc \
        -c "$src" \
        -target arm64-apple-ios${MIN_IOS_VERSION} \
        -sdk "$DEVICE_SDK_PATH" \
        -I "$BUILD_TEMP/openssl_install/include" \
        -I "$BUILD_TEMP/libplist_install/include" \
        -o "$BUILD_TEMP/$obj_name"
    OBJECTS_SWIFT="$OBJECTS_SWIFT $BUILD_TEMP/$obj_name"
done
APP_DIR="$BUILD_TEMP/Payload/$APP_NAME.app"
mkdir -p "$APP_DIR"
echo "  链接可执行文件..."
xcrun -sdk iphoneos clang++ \
    -arch arm64 \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="${MIN_IOS_VERSION}" \
    -o "$APP_DIR/$APP_NAME" \
    $OBJECTS_SWIFT \
    "$LIBS_OUTPUT/libldid2.a" \
    "$LIBS_OUTPUT/libzsign.a" \
    "$LIBS_OUTPUT/libcrypto.a" \
    "$LIBS_OUTPUT/libssl.a" \
    "$LIBS_OUTPUT/libplist-2.0.a" \
    -framework Foundation \
    -framework UIKit \
    -framework CoreGraphics \
    -framework UniformTypeIdentifiers \
    -lc++ -lz
echo -e "${GREEN}  ✅ 可执行文件: $APP_DIR/$APP_NAME${NC}"
# 复制签名工具
cp "$RESOURCES_OUTPUT/ldid2" "$APP_DIR/" 2>/dev/null || true
cp "$RESOURCES_OUTPUT/zsign" "$APP_DIR/" 2>/dev/null || true
chmod +x "$APP_DIR"/* 2>/dev/null || true
# Info.plist
cat > "$APP_DIR/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>PermanentStore</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUM}</string>
    <key>LSRequiresIPhoneOS</key>
    <true/>
    <key>MinimumOSVersion</key>
    <string>${MIN_IOS_VERSION}</string>
</dict>
</plist>
EOF
cp "$ENTITLEMENTS_FILE" "$APP_DIR/entitlements.plist"
# 可选：用 ldid2 进行 ad-hoc 签名（用于巨魔商店）
if [ -f "$APP_DIR/ldid2" ]; then
    "$APP_DIR/ldid2" -S"$ENTITLEMENTS_FILE" "$APP_DIR/$APP_NAME" 2>/dev/null && \
        echo -e "${GREEN}  ✅ ldid2 ad-hoc 签名成功${NC}" || true
fi
# 打包 IPA
cd "$BUILD_TEMP"
IPA_FILE="$IPA_OUTPUT/${APP_NAME}_${VERSION}_${BUILD_NUM}.ipa"
zip -r "$IPA_FILE" Payload > /dev/null
echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}  构建完成！${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "${BLUE}静态库:${NC}"
for lib in libcrypto.a libssl.a libplist-2.0.a libldid2.a libzsign.a; do
    [ -f "$LIBS_OUTPUT/$lib" ] && echo -e "  ${GREEN}✅${NC} $lib ($(du -sh "$LIBS_OUTPUT/$lib" | cut -f1))"
done
echo -e "${BLUE}可执行文件:${NC}"
for tool in ldid2 zsign; do
    [ -f "$RESOURCES_OUTPUT/$tool" ] && echo -e "  ${GREEN}✅${NC} $tool ($(du -sh "$RESOURCES_OUTPUT/$tool" | cut -f1))"
done
echo -e "${BLUE}IPA:${NC}"
[ -f "$IPA_FILE" ] && echo -e "  ${GREEN}✅${NC} $(basename "$IPA_FILE") ($(du -sh "$IPA_FILE" | cut -f1))"
echo -e "\n📁 静态库目录: $LIBS_OUTPUT"
echo -e "📱 IPA 目录: $IPA_OUTPUT"
echo -e "🔐 Entitlements: $ENTITLEMENTS_FILE"
