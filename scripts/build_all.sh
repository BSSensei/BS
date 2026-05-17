#!/bin/bash
set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 错误处理
trap 'echo -e "${RED}❌ 构建失败，退出码: $?${NC}"' ERR

# ============================================================
# 配置区域
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

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  PermanentStore 静态库构建脚本${NC}"
echo -e "${BLUE}  （适用于未越狱设备 + 巨魔商店）${NC}"
echo -e "${BLUE}============================================================${NC}"

# 检查 entitlements
if [ ! -f "$ENTITLEMENTS_FILE" ]; then
    echo -e "${YELLOW}⚠️ entitlements.plist 不存在，创建默认文件${NC}"
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

CPU_CORES=$(sysctl -n hw.ncpu)
[ "$CPU_CORES" -gt 4 ] && CPU_CORES=4

# ============================================================
# 1. 编译 OpenSSL 静态库
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
    no-shared \
    no-tests \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="${MIN_IOS_VERSION}"

make -j"${CPU_CORES}"
make install_sw

cd ..
cp "$BUILD_TEMP/openssl_install/lib/libcrypto.a" "$LIBS_OUTPUT/"
cp "$BUILD_TEMP/openssl_install/lib/libssl.a" "$LIBS_OUTPUT/"
echo -e "${GREEN}  ✅ OpenSSL 静态库${NC}"

# ============================================================
# 2. 编译 libplist 静态库
# ============================================================
echo -e "\n${YELLOW}📦 [2/5] 编译 libplist 静态库${NC}"

# 检查 brew 依赖
if ! command -v libtoolize &> /dev/null; then
    echo -e "${YELLOW}  安装 autotools...${NC}"
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
    --enable-static \
    --disable-shared \
    --disable-tests \
    --host=arm64-apple-darwin

make -j"${CPU_CORES}"
make install

cd ..
cp "$BUILD_TEMP/libplist_install/lib/libplist-2.0.a" "$LIBS_OUTPUT/"
echo -e "${GREEN}  ✅ libplist 静态库${NC}"

# ============================================================
# 3. 编译 ldid 静态库 + 可执行文件
# ============================================================
echo -e "\n${YELLOW}📦 [3/5] 编译 ldid${NC}"

cd "$BUILD_TEMP"
if [ ! -d "ldid_src" ]; then
    git clone https://github.com/ProcursusTeam/ldid.git ldid_src
fi
cd ldid_src

# 编译所有 .cpp 为 .o
OBJECTS=""
for src in *.cpp; do
    if [ -f "$src" ]; then
        obj=$(basename "$src" .cpp).o
        echo "  编译: $src"
        xcrun -sdk iphoneos clang++ \
            -arch arm64 \
            -std=c++17 \
            -fPIC \
            -isysroot "$DEVICE_SDK_PATH" \
            -mios-version-min="${MIN_IOS_VERSION}" \
            -I"$BUILD_TEMP/openssl_install/include" \
            -I"$BUILD_TEMP/libplist_install/include" \
            -c "$src" -o "$obj"
        OBJECTS="$OBJECTS $obj"
    fi
done

# 打包静态库
xcrun -sdk iphoneos ar rcs "$LIBS_OUTPUT/libldid.a" $OBJECTS

# 编译可执行文件（用于签名）
xcrun -sdk iphoneos clang++ \
    -arch arm64 \
    -std=c++17 \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="${MIN_IOS_VERSION}" \
    -I"$BUILD_TEMP/openssl_install/include" \
    -I"$BUILD_TEMP/libplist_install/include" \
    -L"$BUILD_TEMP/openssl_install/lib" \
    -L"$BUILD_TEMP/libplist_install/lib" \
    -lcrypto -lplist-2.0 \
    -o "$RESOURCES_OUTPUT/ldid" ldid.cpp

echo -e "${GREEN}  ✅ ldid 静态库 + 可执行文件${NC}"

# ============================================================
# 4. 编译 zsign 静态库 + 可执行文件
# ============================================================
echo -e "\n${YELLOW}📦 [4/5] 编译 zsign${NC}"

cd "$BUILD_TEMP"
if [ ! -d "zsign_src" ]; then
    git clone https://github.com/zhlynn/zsign.git zsign_src
fi
cd zsign_src

# 修复头文件
for file in *.cpp; do
    [ -f "$file" ] || continue
    sed -i '' '1i\
#include <openssl/x509.h>\
#include <openssl/x509v3.h>\
#include <openssl/asn1.h>\
' "$file" 2>/dev/null || true
    sed -i '' 's/X509_NAME \*nm = X509_get_subject_name/const X509_NAME *nm = X509_get_subject_name/g' "$file"
    sed -i '' 's/X509_NAME \*nm = X509_get_issuer_name/const X509_NAME *nm = X509_get_issuer_name/g' "$file"
done

# 编译
OBJECTS=""
for src in *.cpp; do
    [ -f "$src" ] || continue
    obj=$(basename "$src" .cpp).o
    echo "  编译: $src"
    xcrun -sdk iphoneos clang++ \
        -arch arm64 \
        -std=c++11 \
        -fPIC \
        -isysroot "$DEVICE_SDK_PATH" \
        -mios-version-min="${MIN_IOS_VERSION}" \
        -I"$BUILD_TEMP/openssl_install/include" \
        -c "$src" -o "$obj" 2>/dev/null
    OBJECTS="$OBJECTS $obj"
done

# 打包静态库
xcrun -sdk iphoneos ar rcs "$LIBS_OUTPUT/libzsign.a" $OBJECTS

# 编译可执行文件
if [ -n "$OBJECTS" ]; then
    xcrun -sdk iphoneos clang++ \
        -arch arm64 \
        -isysroot "$DEVICE_SDK_PATH" \
        -mios-version-min="${MIN_IOS_VERSION}" \
        -L"$BUILD_TEMP/openssl_install/lib" \
        -lcrypto -lssl \
        -o "$RESOURCES_OUTPUT/zsign" $OBJECTS 2>/dev/null || true
fi

echo -e "${GREEN}  ✅ zsign 静态库 + 可执行文件${NC}"

# ============================================================
# 5. 编译 Swift 代码
# ============================================================
echo -e "\n${YELLOW}📱 [5/5] 编译 Swift IPA${NC}"

# 查找 Swift 源文件
SWIFT_SOURCES=$(find "$ROOT_DIR" -name "*.swift" -type f 2>/dev/null | grep -v "BuildTemp" | grep -v "Libraries" | grep -v "Resources" | grep -v "IPA" | tr '\n' ' ')

if [ -z "$SWIFT_SOURCES" ]; then
    echo -e "${RED}❌ 未找到 Swift 源文件${NC}"
    exit 1
fi

# 编译 Swift 对象
OBJECTS=""
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
    
    OBJECTS="$OBJECTS $BUILD_TEMP/$obj_name"
done

# 创建应用目录
APP_DIR="$BUILD_TEMP/Payload/$APP_NAME.app"
mkdir -p "$APP_DIR"

# 链接所有静态库
echo "  链接可执行文件..."
xcrun -sdk iphoneos clang++ \
    -arch arm64 \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="${MIN_IOS_VERSION}" \
    -o "$APP_DIR/$APP_NAME" \
    $OBJECTS \
    "$LIBS_OUTPUT/libldid.a" \
    "$LIBS_OUTPUT/libzsign.a" \
    "$LIBS_OUTPUT/libcrypto.a" \
    "$LIBS_OUTPUT/libssl.a" \
    "$LIBS_OUTPUT/libplist-2.0.a" \
    -framework Foundation \
    -framework UIKit \
    -framework CoreGraphics \
    -framework UniformTypeIdentifiers \
    -lc++ \
    -lz

echo -e "${GREEN}  ✅ 可执行文件: $APP_DIR/$APP_NAME${NC}"

# 复制资源
if [ -f "$RESOURCES_OUTPUT/ldid" ]; then
    cp "$RESOURCES_OUTPUT/ldid" "$APP_DIR/"
    chmod +x "$APP_DIR/ldid"
fi

if [ -f "$RESOURCES_OUTPUT/zsign" ]; then
    cp "$RESOURCES_OUTPUT/zsign" "$APP_DIR/"
    chmod +x "$APP_DIR/zsign"
fi

# 创建 Info.plist
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

# 复制 entitlements
cp "$ENTITLEMENTS_FILE" "$APP_DIR/entitlements.plist"

# 签名（使用内置 ldid）
if [ -f "$APP_DIR/ldid" ]; then
    "$APP_DIR/ldid" -S"$ENTITLEMENTS_FILE" "$APP_DIR/$APP_NAME" 2>/dev/null && \
        echo -e "${GREEN}  ✅ 签名成功${NC}" || \
        echo -e "${YELLOW}  ⚠️ 签名跳过${NC}"
fi

# 打包 IPA
cd "$BUILD_TEMP"
IPA_FILE="$IPA_OUTPUT/${APP_NAME}_${VERSION}_${BUILD_NUM}.ipa"
zip -r "$IPA_FILE" Payload > /dev/null

# ============================================================
# 验证产物
# ============================================================
echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}  构建完成！${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""

echo -e "${BLUE}静态库:${NC}"
for lib in libcrypto.a libssl.a libplist-2.0.a libldid.a libzsign.a; do
    if [ -f "$LIBS_OUTPUT/$lib" ]; then
        size=$(du -sh "$LIBS_OUTPUT/$lib" 2>/dev/null | cut -f1)
        echo -e "  ${GREEN}✅${NC} $lib ($size)"
    fi
done

echo ""
echo -e "${BLUE}可执行文件:${NC}"
for tool in ldid zsign; do
    if [ -f "$RESOURCES_OUTPUT/$tool" ]; then
        size=$(du -sh "$RESOURCES_OUTPUT/$tool" 2>/dev/null | cut -f1)
        echo -e "  ${GREEN}✅${NC} $tool ($size)"
    fi
done

echo ""
echo -e "${BLUE}IPA:${NC}"
if [ -f "$IPA_FILE" ]; then
    size=$(du -sh "$IPA_FILE" 2>/dev/null | cut -f1)
    echo -e "  ${GREEN}✅${NC} $(basename "$IPA_FILE") ($size)"
fi

echo ""
echo -e "📁 静态库目录: $LIBS_OUTPUT"
echo -e "📱 IPA 目录: $IPA_OUTPUT"
echo -e "🔐 Entitlements: $ENTITLEMENTS_FILE"
