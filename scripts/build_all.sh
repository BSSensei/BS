#!/bin/bash
set -e

# ===================== 颜色 =====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ===================== 日志系统 =====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$REPO_ROOT"

LOG_FILE="$ROOT_DIR/build_log.txt"
exec > >(tee -i "$LOG_FILE")
exec 2>&1

trap 'echo -e "${RED}❌ 构建失败，详见日志：$LOG_FILE${NC}"; gzip "$LOG_FILE"' ERR

# ===================== 基础配置 =====================
BUILD_TEMP="$ROOT_DIR/BuildTemp"
LIBS_OUTPUT="$ROOT_DIR/Frameworks"
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

# ===================== 使用 GitHub 根目录资源 =====================
INFO_PLIST="$ROOT_DIR/Info.plist"
ICON_FILE="$ROOT_DIR/Icon.png"
ENTITLEMENTS_FILE="$ROOT_DIR/entitlements.plist"

# 验证必需文件
[ ! -f "$INFO_PLIST" ] && echo -e "${RED}❌ 未找到 Info.plist（期望位置：$INFO_PLIST）${NC}" && exit 1
[ ! -f "$ICON_FILE" ] && echo -e "${YELLOW}⚠️ 未找到 Icon.png，将继续构建${NC}"
[ ! -f "$ENTITLEMENTS_FILE" ] && echo -e "${RED}❌ 未找到 entitlements.plist${NC}" && exit 1

echo -e "${GREEN}✅ 使用 GitHub 根目录配置文件${NC}"
echo -e "${BLUE}📁 仓库根目录：$ROOT_DIR${NC}"

# ===================== 环境检测 =====================
echo -e "${BLUE}🔍 检测构建环境...${NC}"
if ! xcrun --version >/dev/null 2>&1; then
    echo -e "${RED}❌ 未检测到 Xcode 工具链${NC}"
    exit 1
fi

# ===================== 安装 Autotools =====================
echo -e "${YELLOW}🔧 校验 Autotools 依赖...${NC}"
if ! command -v libtoolize >/dev/null 2>&1; then
    brew install autoconf automake libtool pkg-config
fi

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  PermanentStore 完整构建（全静态库版）${NC}"
echo -e "${BLUE}  日志文件：$LOG_FILE${NC}"
echo -e "${BLUE}============================================================${NC}"

# ===================== 1. OpenSSL（静态库） =====================
echo -e "\n${YELLOW}📦 [1/5] OpenSSL（静态库）${NC}"
cd "$BUILD_TEMP"
[ -d openssl ] || git clone --depth 1 https://github.com/openssl/openssl.git openssl
cd openssl

export CC="xcrun -sdk iphoneos clang"
export CXX="xcrun -sdk iphoneos clang++"

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
echo -e "${GREEN}✅ OpenSSL（静态库）${NC}"

# ===================== 2. libplist（静态库） =====================
echo -e "\n${YELLOW}📦 [2/5] libplist（静态库）${NC}"
cd "$BUILD_TEMP"
[ -d libplist ] || git clone --depth 1 https://github.com/libimobiledevice/libplist.git libplist
cd libplist

[ ! -f configure ] && ./autogen.sh
make clean >/dev/null 2>&1 || true

# ✅ 强制声明交叉编译（GitHub Actions 必选）
export ac_cv_func_malloc_0_nonnull=yes
export ac_cv_func_realloc_0_nonnull=yes
export ac_cv_file__dev_zero=yes
export ac_cv_func_setvbuf_reversed=no

./configure \
    --prefix="$BUILD_TEMP/libplist_install" \
    --host=arm-apple-darwin \
    --build=x86_64-apple-darwin \
    --enable-static \
    --disable-shared \
    --disable-dependency-tracking \
    --disable-tests \
    --disable-doxygen-docs \
    CC="xcrun -sdk iphoneos clang" \
    CXX="xcrun -sdk iphoneos clang++" \
    CFLAGS="-arch arm64 -isysroot $DEVICE_SDK_PATH -mios-version-min=$MIN_IOS_VERSION" \
    CXXFLAGS="-arch arm64 -isysroot $DEVICE_SDK_PATH -mios-version-min=$MIN_IOS_VERSION"

make -j"$CPU_CORES"
make install
cp "$BUILD_TEMP/libplist_install/lib/libplist-2.0.a" "$LIBS_OUTPUT/"
echo -e "${GREEN}✅ libplist（静态库）${NC}"

# ===================== 3. ldid（静态库） =====================
echo -e "\n${YELLOW}📦 [3/5] ldid（静态库）${NC}"
cd "$BUILD_TEMP"

LDID_REPO="https://github.com/ProcursusTeam/ldid.git"
CLONE_DIR="ldid"

for i in {1..3}; do
    echo "尝试克隆 ldid (第 $i 次)..."
    rm -rf "$CLONE_DIR"
    if git clone --depth 1 "$LDID_REPO" "$CLONE_DIR"; then
        echo -e "${GREEN}✅ ldid 克隆成功${NC}"
        break
    else
        echo -e "${YELLOW}⚠️ 克隆失败，等待 5 秒后重试...${NC}"
        sleep 5
        [ $i -eq 3 ] && echo -e "${RED}❌ ldid 克隆失败${NC}" && exit 1
    fi
done

cd "$CLONE_DIR"
[ ! -f "ldid.cpp" ] && echo -e "${RED}❌ 未找到 ldid.cpp${NC}" && exit 1

# ✅ 编译为静态库（不是可执行文件）
clang++ -std=c++17 \
    -arch arm64 \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="$MIN_IOS_VERSION" \
    -stdlib=libc++ \
    -c \
    -I"$BUILD_TEMP/openssl_install/include" \
    ldid.cpp \
    -o ldid.o

ar rcs "$LIBS_OUTPUT/libldid.a" ldid.o
echo -e "${GREEN}✅ ldid（静态库）${NC}"

# ===================== 4. zsign（静态库） =====================
echo -e "\n${YELLOW}📦 [4/5] zsign（静态库）${NC}"
cd "$BUILD_TEMP"
[ -d zsign ] || git clone --depth 1 https://github.com/zhlynn/zsign.git zsign
cd zsign

# ✅ 编译所有源文件为静态库
clang++ -std=c++11 \
    -arch arm64 \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="$MIN_IOS_VERSION" \
    -stdlib=libc++ \
    -c \
    -I"$BUILD_TEMP/openssl_install/include" \
    -I"$BUILD_TEMP/libplist_install/include" \
    *.cpp

# 创建静态库
ar rcs "$LIBS_OUTPUT/libzsign.a" *.o
echo -e "${GREEN}✅ zsign（静态库）${NC}"

# ===================== 5. Swift App（链接所有静态库） =====================
echo -e "\n${YELLOW}📦 [5/5] Swift App${NC}"
SWIFT_FILES=$(find "$ROOT_DIR" -name "*.swift" ! -path "*/BuildTemp/*" ! -path "*/.git/*")
[ -z "$SWIFT_FILES" ] && echo -e "${RED}❌ 未找到 Swift 文件${NC}" && exit 1

APP_DIR="$BUILD_TEMP/Payload/$APP_NAME.app"
mkdir -p "$APP_DIR"

# 编译 Swift 可执行文件，链接所有静态库
xcrun -sdk iphoneos swiftc \
    -target arm64-apple-ios$MIN_IOS_VERSION \
    -sdk "$DEVICE_SDK_PATH" \
    -emit-executable \
    -I "$BUILD_TEMP/openssl_install/include" \
    -I "$BUILD_TEMP/libplist_install/include" \
    -L "$LIBS_OUTPUT" \
    -lcrypto -lssl -lplist-2.0 -lldid -lzsign \
    -framework Foundation \
    -framework UIKit \
    -framework UniformTypeIdentifiers \
    -o "$APP_DIR/$APP_NAME" \
    $SWIFT_FILES

# 复制 Swift runtime
mkdir -p "$APP_DIR/Frameworks"
cp -R "$(xcrun --sdk iphoneos --show-sdk-path)/usr/lib/swift"/*.dylib "$APP_DIR/Frameworks/" 2>/dev/null || true

# 设置执行权限
chmod +x "$APP_DIR/$APP_NAME" 2>/dev/null || true

# ===================== 使用 GitHub 根目录 Info.plist =====================
cp "$INFO_PLIST" "$APP_DIR/Info.plist"

# 替换 Info.plist 中的变量
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP_NAME" "$APP_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName PermanentStore" "$APP_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUM" "$APP_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MinimumOSVersion $MIN_IOS_VERSION" "$APP_DIR/Info.plist"

# 复制图标文件
[ -f "$ICON_FILE" ] && cp "$ICON_FILE" "$APP_DIR/Icon.png"

# 复制 entitlements
cp "$ENTITLEMENTS_FILE" "$APP_DIR/entitlements.plist"

# ===================== 签名 =====================
if command -v ldid >/dev/null 2>&1; then
    # 先签 frameworks
    find "$APP_DIR/Frameworks" -name "*.dylib" -exec ldid -S"$APP_DIR/entitlements.plist" {} \; 2>/dev/null || true
    # 再签主程序
    ldid -S"$APP_DIR/entitlements.plist" "$APP_DIR/$APP_NAME" 2>/dev/null || \
    echo -e "${YELLOW}⚠️ ldid 签名失败（无巨魔环境可忽略）${NC}"
fi

# ===================== 打包 IPA =====================
cd "$BUILD_TEMP"
IPA_PATH="$IPA_OUTPUT/${APP_NAME}_${VERSION}_${BUILD_NUM}.ipa"
zip -qr "$IPA_PATH" Payload

# ===================== 完成 =====================
echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}  构建完成 ✅${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "${BLUE}📦 静态库路径：$LIBS_OUTPUT${NC}"
echo -e "${BLUE}📦 IPA 路径：$IPA_PATH${NC}"
echo -e "${BLUE}📄 构建日志：$LOG_FILE${NC}"

gzip "$LOG_FILE"
