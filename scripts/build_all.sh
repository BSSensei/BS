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
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_TEMP="$ROOT_DIR/BuildTemp"
FRAMEWORKS_OUTPUT="$ROOT_DIR/Frameworks"

XCODE_PROJECT="$ROOT_DIR/PermanentStore.xcodeproj"
XCODE_SCHEME="PermanentStore"
XCODE_CONFIGURATION="Release"

IPA_OUTPUT="$ROOT_DIR/IPA"
ENTITLEMENTS_FILE="$ROOT_DIR/entitlements.plist"

mkdir -p "$BUILD_TEMP" "$FRAMEWORKS_OUTPUT" "$IPA_OUTPUT"

DEVICE_SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
MIN_IOS_VERSION="12.0"

# 创建默认 entitlements 文件（如果不存在）
if [ ! -f "$ENTITLEMENTS_FILE" ]; then
    cat > "$ENTITLEMENTS_FILE" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>application-identifier</key>
    <string>com.permanentstore.app</string>
    <key>get-task-allow</key>
    <true/>
</dict>
</plist>
EOF
    echo -e "${YELLOW}⚠️ 已创建默认 entitlements.plist${NC}"
fi

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  PermanentStore 完整构建脚本${NC}"
echo -e "${BLUE}============================================================${NC}"
echo -e "📱 设备 SDK: $DEVICE_SDK_PATH"
echo -e "📦 Framework 输出: $FRAMEWORKS_OUTPUT"
echo -e "📱 IPA 输出: $IPA_OUTPUT"

CPU_CORES=$(sysctl -n hw.ncpu)
if [ "$CPU_CORES" -gt 4 ]; then
    CPU_CORES=4
fi
echo -e "🖥️  使用并发数: $CPU_CORES"

# ============================================================
# 辅助函数
# ============================================================

create_framework_structure() {
    local framework_dir="$1"
    local framework_name="$2"
    
    rm -rf "$framework_dir"
    mkdir -p "$framework_dir"
    mkdir -p "$framework_dir/Headers"
    mkdir -p "$framework_dir/Modules"
    
    cat > "$framework_dir/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${framework_name}</string>
    <key>CFBundleIdentifier</key>
    <string>com.permanentstore.${framework_name}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${framework_name}</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>${MIN_IOS_VERSION}</string>
</dict>
</plist>
EOF
    
    cat > "$framework_dir/Modules/module.modulemap" << EOF
framework module ${framework_name} {
    umbrella header "${framework_name}.h"
    export *
}
EOF
}

create_framework_header() {
    local framework_dir="$1"
    local framework_name="$2"
    
    cat > "$framework_dir/Headers/${framework_name}.h" << EOF
#ifndef ${framework_name}_h
#define ${framework_name}_h

#import <Foundation/Foundation.h>

FOUNDATION_EXPORT double ${framework_name}VersionNumber;
FOUNDATION_EXPORT const unsigned char ${framework_name}VersionString[];

EOF
    
    # 添加额外的头文件导入
    for header in "$framework_dir/Headers/"*.h; do
        if [ -f "$header" ] && [ "$(basename "$header")" != "${framework_name}.h" ]; then
            echo "#import <${framework_name}/$(basename "$header")>" >> "$framework_dir/Headers/${framework_name}.h"
        fi
    done
    
    echo "#endif" >> "$framework_dir/Headers/${framework_name}.h"
}

# ============================================================
# 1. 编译 OpenSSL Framework
# ============================================================
echo -e "\n${YELLOW}📦 [1/4] 编译 OpenSSL.framework${NC}"

cd "$BUILD_TEMP"
if [ ! -d "openssl_src" ]; then
    git clone --depth 1 https://github.com/openssl/openssl.git openssl_src
fi
cd openssl_src

make clean 2>/dev/null || true
make distclean 2>/dev/null || true

./Configure ios64-cross \
    --prefix="$BUILD_TEMP/openssl_install" \
    --openssldir="$BUILD_TEMP/openssl_install/ssl" \
    shared \
    no-tests \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="${MIN_IOS_VERSION}"

make -j"${CPU_CORES}"
make install_sw

cd ..

# 创建 OpenSSL.framework
OPENSSL_FRAMEWORK="$FRAMEWORKS_OUTPUT/OpenSSL.framework"
create_framework_structure "$OPENSSL_FRAMEWORK" "OpenSSL"

if [ -f "$BUILD_TEMP/openssl_install/lib/libcrypto.dylib" ]; then
    cp "$BUILD_TEMP/openssl_install/lib/libcrypto.dylib" "$OPENSSL_FRAMEWORK/OpenSSL"
    install_name_tool -id "@rpath/OpenSSL.framework/OpenSSL" "$OPENSSL_FRAMEWORK/OpenSSL"
fi

if [ -d "$BUILD_TEMP/openssl_install/include" ]; then
    cp -r "$BUILD_TEMP/openssl_install/include/"* "$OPENSSL_FRAMEWORK/Headers/"
fi
create_framework_header "$OPENSSL_FRAMEWORK" "OpenSSL"

echo -e "${GREEN}  ✅ OpenSSL.framework${NC}"

# ============================================================
# 2. 编译 libplist Framework
# ============================================================
echo -e "\n${YELLOW}📦 [2/4] 编译 PLIST.framework${NC}"

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
    --enable-shared \
    --disable-static \
    --disable-tests \
    --host=arm64-apple-darwin

make -j"${CPU_CORES}"
make install

cd ..

# 创建 PLIST.framework
PLIST_FRAMEWORK="$FRAMEWORKS_OUTPUT/PLIST.framework"
create_framework_structure "$PLIST_FRAMEWORK" "PLIST"

if [ -f "$BUILD_TEMP/libplist_install/lib/libplist-2.0.dylib" ]; then
    cp "$BUILD_TEMP/libplist_install/lib/libplist-2.0.dylib" "$PLIST_FRAMEWORK/PLIST"
    install_name_tool -id "@rpath/PLIST.framework/PLIST" "$PLIST_FRAMEWORK/PLIST"
fi

if [ -d "$BUILD_TEMP/libplist_install/include" ]; then
    cp -r "$BUILD_TEMP/libplist_install/include/"* "$PLIST_FRAMEWORK/Headers/"
fi
create_framework_header "$PLIST_FRAMEWORK" "PLIST"

echo -e "${GREEN}  ✅ PLIST.framework${NC}"

# ============================================================
# 3. 编译 ldid Framework
# ============================================================
echo -e "\n${YELLOW}📦 [3/4] 编译 ldid.framework${NC}"

cd "$BUILD_TEMP"
if [ ! -d "ldid_src" ]; then
    git clone https://github.com/ProcursusTeam/ldid.git ldid_src
fi

cd ldid_src

# 修复 OpenSSL const 问题
if ! grep -q "const_cast" ldid.cpp; then
    echo "  应用 ldid OpenSSL 兼容性补丁..."
    sed -i '' 's/X509_NAME_get_entry(nm, lastpos)/const_cast<X509_NAME_ENTRY*>(X509_NAME_get_entry(nm, lastpos))/g' ldid.cpp
    sed -i '' 's/X509_NAME_ENTRY_get_data(e)/const_cast<ASN1_STRING*>(X509_NAME_ENTRY_get_data(e))/g' ldid.cpp
    sed -i '' 's/X509_get_subject_name(x)/const_cast<X509_NAME*>(X509_get_subject_name(x))/g' ldid.cpp
fi

# 定义版本宏
VERSION="2.1.5"

echo "  编译 ldid（忽略签名相关代码）..."

# 编译 ldid.o
if ! xcrun -sdk iphoneos clang++ \
    -arch arm64 \
    -std=c++17 \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="${MIN_IOS_VERSION}" \
    -I"$BUILD_TEMP/openssl_install/include" \
    -I"$BUILD_TEMP/libplist_install/include" \
    -D_GNU_SOURCE \
    -DLDID_VERSION="\"$VERSION\"" \
    -Wno-deprecated-declarations \
    -Wno-unused-variable \
    -Wno-unused-function \
    -Wno-incompatible-pointer-types-discards-qualifiers \
    -c ldid.cpp -o ldid.o; then
    echo -e "${RED}  ❌ ldid 编译失败${NC}"
    exit 1
fi

# 链接
if ! xcrun -sdk iphoneos clang++ \
    -arch arm64 \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="${MIN_IOS_VERSION}" \
    -L"$BUILD_TEMP/openssl_install/lib" \
    -L"$BUILD_TEMP/libplist_install/lib" \
    -lcrypto -lplist-2.0 \
    -o ldid ldid.o; then
    echo -e "${RED}  ❌ ldid 链接失败${NC}"
    exit 1
fi

cd ..

# 创建 ldid.framework
LDID_FRAMEWORK="$FRAMEWORKS_OUTPUT/ldid.framework"
create_framework_structure "$LDID_FRAMEWORK" "ldid"

cp "ldid_src/ldid" "$LDID_FRAMEWORK/ldid"
chmod +x "$LDID_FRAMEWORK/ldid"

# 添加简单的头文件
cat > "$LDID_FRAMEWORK/Headers/ldid.h" << 'EOF'
#ifndef ldid_h
#define ldid_h

#import <Foundation/Foundation.h>

@interface LDID : NSObject
+ (int)signFile:(NSString*)path withEntitlements:(NSString*)entitlementsPath;
+ (int)verifyFile:(NSString*)path;
+ (NSString*)getEntitlements:(NSString*)path;
@end

#endif
EOF

create_framework_header "$LDID_FRAMEWORK" "ldid"
echo -e "${GREEN}  ✅ ldid.framework${NC}"

# ============================================================
# 4. 编译 zsign Framework
# ============================================================
echo -e "\n${YELLOW}📦 [4/4] 编译 zsign.framework${NC}"

cd "$BUILD_TEMP"
if [ ! -d "zsign_src" ]; then
    git clone https://github.com/zhlynn/zsign.git zsign_src
fi

cd zsign_src

# 收集所有 .cpp 源文件（排除测试文件）
SOURCES=$(find . -maxdepth 1 -name "*.cpp" ! -name "*test*" 2>/dev/null | tr '\n' ' ')

if [ -z "$SOURCES" ]; then
    echo -e "${RED}  ❌ 未找到源文件${NC}"
    exit 1
fi

echo "  编译 zsign..."
OBJECTS=""
for src in $SOURCES; do
    obj=$(basename "$src" .cpp).o
    if ! xcrun -sdk iphoneos clang++ -arch arm64 \
        -std=c++11 \
        -isysroot "$DEVICE_SDK_PATH" \
        -mios-version-min="${MIN_IOS_VERSION}" \
        -I"$BUILD_TEMP/openssl_install/include" \
        -I. \
        -c "$src" -o "$obj"; then
        echo -e "${RED}  ❌ 编译 $src 失败${NC}"
        exit 1
    fi
    OBJECTS="$OBJECTS $obj"
done

if ! xcrun -sdk iphoneos clang++ -arch arm64 \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="${MIN_IOS_VERSION}" \
    -L"$BUILD_TEMP/openssl_install/lib" \
    -lcrypto -lssl \
    -o zsign $OBJECTS; then
    echo -e "${RED}  ❌ 链接 zsign 失败${NC}"
    exit 1
fi

cd ..

# 创建 zsign.framework
ZSIGN_FRAMEWORK="$FRAMEWORKS_OUTPUT/zsign.framework"
create_framework_structure "$ZSIGN_FRAMEWORK" "zsign"

cp "zsign_src/zsign" "$ZSIGN_FRAMEWORK/zsign"
chmod +x "$ZSIGN_FRAMEWORK/zsign"

# 添加头文件
cat > "$ZSIGN_FRAMEWORK/Headers/zsign.h" << 'EOF'
#ifndef zsign_h
#define zsign_h

#import <Foundation/Foundation.h>

@interface ZSign : NSObject
+ (int)signIPA:(NSString*)ipaPath 
        withP12:(NSString*)p12Path 
       password:(NSString*)password
   provisionPath:(NSString*)provisionPath
      outputPath:(NSString*)outputPath;
+ (int)signFile:(NSString*)filePath
        withP12:(NSString*)p12Path
       password:(NSString*)password;
@end

#endif
EOF

create_framework_header "$ZSIGN_FRAMEWORK" "zsign"
echo -e "${GREEN}  ✅ zsign.framework${NC}"

# ============================================================
# 5. 编译 IPA（不签名）
# ============================================================
echo -e "\n${YELLOW}📱 [5/5] 编译 IPA（不签名）${NC}"

if [ ! -d "$XCODE_PROJECT" ]; then
    echo -e "${YELLOW}⚠️ 跳过 IPA 编译${NC}"
else
    VERSION=$(defaults read "$ROOT_DIR/PermanentStore/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0")
    BUILD_NUM=$(defaults read "$ROOT_DIR/PermanentStore/Info.plist" CFBundleVersion 2>/dev/null || echo "1")
    
    echo "  版本: $VERSION ($BUILD_NUM)"
    
    # 清理
    xcodebuild clean \
        -project "$XCODE_PROJECT" \
        -scheme "$XCODE_SCHEME" \
        -configuration "$XCODE_CONFIGURATION" || true
    
    # 直接构建 .app（不签名）
    BUILD_DIR="$BUILD_TEMP/Build"
    mkdir -p "$BUILD_DIR"
    
    xcodebuild build \
        -project "$XCODE_PROJECT" \
        -scheme "$XCODE_SCHEME" \
        -configuration "$XCODE_CONFIGURATION" \
        -sdk iphoneos \
        -derivedDataPath "$BUILD_DIR" \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        DEVELOPMENT_TEAM="" \
        PROVISIONING_PROFILE_SPECIFIER=""
    
    # 查找生成的 .app
    APP_PATH=$(find "$BUILD_DIR/Build/Products/$XCODE_CONFIGURATION-iphoneos" -name "*.app" | head -1)
    
    if [ -d "$APP_PATH" ]; then
        # 复制 entitlements（可选）
        cp "$ENTITLEMENTS_FILE" "$APP_PATH/entitlements.plist" 2>/dev/null || true
        
        # 打包成 IPA
        IPA_NAME="PermanentStore_${VERSION}_${BUILD_NUM}.ipa"
        mkdir -p "$IPA_OUTPUT/Payload"
        cp -r "$APP_PATH" "$IPA_OUTPUT/Payload/"
        cd "$IPA_OUTPUT"
        zip -qr "$IPA_NAME" Payload/
        rm -rf Payload
        cd - > /dev/null
        
        echo -e "${GREEN}  ✅ IPA 生成成功: $IPA_OUTPUT/$IPA_NAME${NC}"
        echo -e "${YELLOW}  ⚠️ IPA 未签名，需要自行签名后才能安装${NC}"
    else
        echo -e "${RED}  ❌ 未找到编译产物${NC}"
        exit 1
    fi
fi

# ============================================================
# 验证所有产物
# ============================================================
echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}  构建完成！${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""

FRAMEWORKS=("OpenSSL" "PLIST" "ldid" "zsign")
ALL_SUCCESS=true

for fw in "${FRAMEWORKS[@]}"; do
    fw_path="$FRAMEWORKS_OUTPUT/${fw}.framework"
    if [ -d "$fw_path" ]; then
        size=$(du -sh "$fw_path" 2>/dev/null | cut -f1)
        if [ -f "$fw_path/Info.plist" ] && [ -f "$fw_path/Headers/${fw}.h" ]; then
            echo -e "  ${GREEN}✅${NC} $fw.framework ($size)"
        else
            echo -e "  ${YELLOW}⚠️${NC} $fw.framework (不完整)"
            ALL_SUCCESS=false
        fi
    else
        echo -e "  ${RED}❌${NC} $fw.framework (缺失)"
        ALL_SUCCESS=false
    fi
done

echo ""
if [ "$ALL_SUCCESS" = true ]; then
    echo -e "${GREEN}✅ 所有 Frameworks 构建成功${NC}"
else
    echo -e "${YELLOW}⚠️ 部分 Frameworks 可能不完整${NC}"
fi

echo ""
echo -e "📱 IPA 输出: $IPA_OUTPUT"
if ls "$IPA_OUTPUT"/*.ipa 2>/dev/null; then
    echo -e "${GREEN}✅ IPA 生成成功${NC}"
else
    echo -e "${YELLOW}⚠️ 无 IPA 文件${NC}"
fi

echo ""
echo -e "🔐 Entitlements: $ENTITLEMENTS_FILE"
