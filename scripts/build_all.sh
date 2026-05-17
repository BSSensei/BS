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

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  PermanentStore 完整构建脚本${NC}"
echo -e "${BLUE}============================================================${NC}"
echo -e "📱 设备 SDK: $DEVICE_SDK_PATH"
echo -e "📦 Framework 输出: $FRAMEWORKS_OUTPUT"
echo -e "📱 IPA 输出: $IPA_OUTPUT"
echo -e "🔐 Entitlements: $ENTITLEMENTS_FILE"

CPU_CORES=$(sysctl -n hw.ncpu)
if [ "$CPU_CORES" -gt 4 ]; then
    CPU_CORES=4
fi
echo -e "🖥️  使用并发数: $CPU_CORES"

# 检查根目录 entitlements 是否存在
if [ ! -f "$ENTITLEMENTS_FILE" ]; then
    echo -e "${RED}  ❌ 根目录 entitlements.plist 不存在: $ENTITLEMENTS_FILE${NC}"
    echo -e "${YELLOW}  请在项目根目录创建 entitlements.plist 文件${NC}"
    exit 1
fi

# ============================================================
# 辅助函数 - 创建动态 Framework 结构
# ============================================================

create_dynamic_framework() {
    local framework_dir="$1"
    local framework_name="$2"
    local dylib_path="$3"
    
    rm -rf "$framework_dir"
    mkdir -p "$framework_dir"
    mkdir -p "$framework_dir/Headers"
    mkdir -p "$framework_dir/Modules"
    mkdir -p "$framework_dir/Resources"
    
    # 复制动态库并重命名
    if [ -f "$dylib_path" ]; then
        cp "$dylib_path" "$framework_dir/$framework_name"
        chmod 755 "$framework_dir/$framework_name"
        # 修改动态库的 install name
        install_name_tool -id "@rpath/${framework_name}.framework/${framework_name}" "$framework_dir/$framework_name" 2>/dev/null || true
    fi
    
    # 创建 Info.plist
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
    
    # 创建 modulemap
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
    
    if [ -d "$framework_dir/Headers" ]; then
        for header in "$framework_dir/Headers/"*.h; do
            if [ -f "$header" ] && [ "$(basename "$header")" != "${framework_name}.h" ]; then
                echo "#import <${framework_name}/$(basename "$header")>" >> "$framework_dir/Headers/${framework_name}.h"
            fi
        done 2>/dev/null || true
    fi
    
    echo "#endif" >> "$framework_dir/Headers/${framework_name}.h"
}

# ============================================================
# 1. 编译 OpenSSL.framework (动态库)
# ============================================================
echo -e "\n${YELLOW}📦 [1/5] 编译 OpenSSL.framework (动态库)${NC}"

cd "$BUILD_TEMP"
if [ ! -d "openssl_src" ]; then
    git clone --depth 1 --branch OpenSSL_1_1_1-stable https://github.com/openssl/openssl.git openssl_src
fi
cd openssl_src

make clean 2>/dev/null || true
make distclean 2>/dev/null || true

# 配置为动态库
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

# 创建动态 Framework
OPENSSL_FRAMEWORK="$FRAMEWORKS_OUTPUT/OpenSSL.framework"
OPENSSL_DYLIB="$BUILD_TEMP/openssl_install/lib/libcrypto.dylib"

if [ -f "$OPENSSL_DYLIB" ]; then
    create_dynamic_framework "$OPENSSL_FRAMEWORK" "OpenSSL" "$OPENSSL_DYLIB"
    
    # 复制头文件
    if [ -d "$BUILD_TEMP/openssl_install/include" ]; then
        cp -r "$BUILD_TEMP/openssl_install/include/"* "$OPENSSL_FRAMEWORK/Headers/"
    fi
    create_framework_header "$OPENSSL_FRAMEWORK" "OpenSSL"
    
    echo -e "${GREEN}  ✅ OpenSSL.framework (动态库)${NC}"
else
    echo -e "${RED}  ❌ OpenSSL 动态库编译失败${NC}"
    exit 1
fi

# ============================================================
# 2. 编译 PLIST.framework (动态库)
# ============================================================
echo -e "\n${YELLOW}📦 [2/5] 编译 PLIST.framework (动态库)${NC}"

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

# 配置为动态库
./configure \
    --prefix="$BUILD_TEMP/libplist_install" \
    --enable-shared \
    --disable-static \
    --disable-tests \
    --host=arm64-apple-darwin

make -j"${CPU_CORES}"
make install

cd ..

# 创建动态 Framework
PLIST_FRAMEWORK="$FRAMEWORKS_OUTPUT/PLIST.framework"
PLIST_DYLIB="$BUILD_TEMP/libplist_install/lib/libplist-2.0.dylib"

if [ -f "$PLIST_DYLIB" ]; then
    create_dynamic_framework "$PLIST_FRAMEWORK" "PLIST" "$PLIST_DYLIB"
    
    # 复制头文件
    if [ -d "$BUILD_TEMP/libplist_install/include" ]; then
        cp -r "$BUILD_TEMP/libplist_install/include/"* "$PLIST_FRAMEWORK/Headers/"
    fi
    create_framework_header "$PLIST_FRAMEWORK" "PLIST"
    
    echo -e "${GREEN}  ✅ PLIST.framework (动态库)${NC}"
else
    echo -e "${RED}  ❌ PLIST 动态库编译失败${NC}"
    exit 1
fi

# ============================================================
# 3. 编译 ldid.framework (动态库)
# ============================================================
echo -e "\n${YELLOW}📦 [3/5] 编译 ldid.framework (动态库)${NC}"

cd "$BUILD_TEMP"
if [ ! -d "ldid_src" ]; then
    git clone https://github.com/ProcursusTeam/ldid.git ldid_src
fi

cd ldid_src

# 应用 OpenSSL 兼容性修复
if ! grep -q "const X509_NAME" ldid.cpp 2>/dev/null; then
    echo "  应用 OpenSSL 兼容性补丁..."
    sed -i '' 's/X509_NAME \*name/const X509_NAME *name/g' ldid.cpp
    sed -i '' 's/X509_NAME_get_index_by_NID(name,/X509_NAME_get_index_by_NID(const_cast<X509_NAME*>(name),/g' ldid.cpp
    sed -i '' 's/X509_NAME_get_entry(name,/X509_NAME_get_entry(const_cast<X509_NAME*>(name),/g' ldid.cpp
fi

# 编译为动态库
echo "  编译 ldid 动态库..."

# 编译每个目标文件
xcrun -sdk iphoneos clang++ \
    -arch arm64 \
    -std=c++17 \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="${MIN_IOS_VERSION}" \
    -I"$BUILD_TEMP/openssl_install/include" \
    -I"$BUILD_TEMP/libplist_install/include" \
    -DLDID_VERSION='"2.1.5"' \
    -fPIC \
    -c ldid.cpp -o ldid.o 2>/dev/null || true

xcrun -sdk iphoneos clang++ \
    -arch arm64 \
    -std=c++17 \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="${MIN_IOS_VERSION}" \
    -fPIC \
    -c lookup2.cpp -o lookup2.o 2>/dev/null || true

xcrun -sdk iphoneos clang \
    -arch arm64 \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="${MIN_IOS_VERSION}" \
    -fPIC \
    -c sha1.c -o sha1.o 2>/dev/null || true

# 创建动态库
xcrun -sdk iphoneos clang++ \
    -arch arm64 \
    -dynamiclib \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="${MIN_IOS_VERSION}" \
    -L"$BUILD_TEMP/openssl_install/lib" \
    -L"$BUILD_TEMP/libplist_install/lib" \
    -lcrypto -lplist-2.0 \
    -install_name "@rpath/ldid.framework/ldid" \
    -o libldid.dylib ldid.o lookup2.o sha1.o 2>/dev/null || true

cd ..

# 创建动态 Framework
LDID_FRAMEWORK="$FRAMEWORKS_OUTPUT/ldid.framework"
LDID_DYLIB="ldid_src/libldid.dylib"

if [ -f "$LDID_DYLIB" ]; then
    create_dynamic_framework "$LDID_FRAMEWORK" "ldid" "$LDID_DYLIB"
    
    cat > "$LDID_FRAMEWORK/Headers/ldid.h" << 'EOF'
#ifndef ldid_h
#define ldid_h

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

int ldid_sign(const char* path, const char* entitlements_path);
int ldid_verify(const char* path);
char* ldid_get_entitlements(const char* path);

#ifdef __cplusplus
}
#endif

@interface LDID : NSObject
+ (int)signFile:(NSString*)path withEntitlements:(NSString*)entitlementsPath;
+ (int)verifyFile:(NSString*)path;
+ (NSString*)getEntitlements:(NSString*)path;
@end

#endif
EOF
    
    create_framework_header "$LDID_FRAMEWORK" "ldid"
    echo -e "${GREEN}  ✅ ldid.framework (动态库)${NC}"
else
    echo -e "${YELLOW}  ⚠️ ldid 动态库编译失败，跳过${NC}"
fi

# ============================================================
# 4. 编译 zsign.framework (动态库)
# ============================================================
echo -e "\n${YELLOW}📦 [4/5] 编译 zsign.framework (动态库)${NC}"

cd "$BUILD_TEMP"
if [ ! -d "zsign_src" ]; then
    git clone https://github.com/zhlynn/zsign.git zsign_src
fi

cd zsign_src

# 编译所有源文件为 PIC
OBJS=""
for src in *.c 2>/dev/null; do
    if [ -f "$src" ]; then
        obj="${src%.c}.o"
        xcrun -sdk iphoneos clang \
            -arch arm64 \
            -fPIC \
            -isysroot "$DEVICE_SDK_PATH" \
            -mios-version-min="${MIN_IOS_VERSION}" \
            -I"$BUILD_TEMP/openssl_install/include" \
            -c "$src" -o "$obj" 2>/dev/null
        OBJS="$OBJS $obj"
    fi
done

for src in *.cpp 2>/dev/null; do
    if [ -f "$src" ]; then
        obj="${src%.cpp}.o"
        xcrun -sdk iphoneos clang++ \
            -arch arm64 \
            -std=c++11 \
            -fPIC \
            -isysroot "$DEVICE_SDK_PATH" \
            -mios-version-min="${MIN_IOS_VERSION}" \
            -I"$BUILD_TEMP/openssl_install/include" \
            -c "$src" -o "$obj" 2>/dev/null
        OBJS="$OBJS $obj"
    fi
done

# 创建动态库
if [ -n "$OBJS" ]; then
    xcrun -sdk iphoneos clang++ \
        -arch arm64 \
        -dynamiclib \
        -isysroot "$DEVICE_SDK_PATH" \
        -mios-version-min="${MIN_IOS_VERSION}" \
        -L"$BUILD_TEMP/openssl_install/lib" \
        -lcrypto \
        -install_name "@rpath/zsign.framework/zsign" \
        -o libzsign.dylib $OBJS 2>/dev/null || true
fi

cd ..

# 创建动态 Framework
ZSIGN_FRAMEWORK="$FRAMEWORKS_OUTPUT/zsign.framework"
ZSIGN_DYLIB="zsign_src/libzsign.dylib"

if [ -f "$ZSIGN_DYLIB" ]; then
    create_dynamic_framework "$ZSIGN_FRAMEWORK" "zsign" "$ZSIGN_DYLIB"
    
    cat > "$ZSIGN_FRAMEWORK/Headers/zsign.h" << 'EOF'
#ifndef zsign_h
#define zsign_h

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

int zsign_sign_ipa(const char* ipa_path, const char* p12_path, const char* password, 
                   const char* provision_path, const char* output_path);
int zsign_sign_file(const char* file_path, const char* p12_path, const char* password);

#ifdef __cplusplus
}
#endif

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
    echo -e "${GREEN}  ✅ zsign.framework (动态库)${NC}"
else
    echo -e "${YELLOW}  ⚠️ zsign 动态库编译失败，跳过${NC}"
fi

# ============================================================
# 5. 编译 IPA
# ============================================================
echo -e "\n${YELLOW}📱 [5/5] 编译 IPA${NC}"

if [ ! -d "$XCODE_PROJECT" ]; then
    echo -e "${YELLOW}  ⚠️ 未找到 Xcode 项目，跳过 IPA 编译${NC}"
else
    VERSION=$(defaults read "$ROOT_DIR/PermanentStore/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0")
    BUILD_NUM=$(defaults read "$ROOT_DIR/PermanentStore/Info.plist" CFBundleVersion 2>/dev/null || echo "1")
    
    echo "  版本: $VERSION ($BUILD_NUM)"
    
    BUILD_DIR="$BUILD_TEMP/Build"
    mkdir -p "$BUILD_DIR"
    
    # 构建
    xcodebuild build \
        -project "$XCODE_PROJECT" \
        -scheme "$XCODE_SCHEME" \
        -configuration "$XCODE_CONFIGURATION" \
        -sdk iphoneos \
        -derivedDataPath "$BUILD_DIR" \
        FRAMEWORK_SEARCH_PATHS="$FRAMEWORKS_OUTPUT" \
        LD_RUNPATH_SEARCH_PATHS="@executable_path/Frameworks @loader_path/Frameworks" \
        CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS_FILE" \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO || true
    
    # 查找 .app
    APP_PATH=$(find "$BUILD_DIR/Build/Products/$XCODE_CONFIGURATION-iphoneos" -name "*.app" 2>/dev/null | head -1)
    
    if [ -d "$APP_PATH" ]; then
        # 复制动态 Frameworks 到 app 中
        mkdir -p "$APP_PATH/Frameworks"
        for framework in "$FRAMEWORKS_OUTPUT"/*.framework; do
            if [ -d "$framework" ]; then
                cp -r "$framework" "$APP_PATH/Frameworks/"
                echo "  复制 Framework: $(basename "$framework")"
            fi
        done
        
        # 复制 entitlements
        cp "$ENTITLEMENTS_FILE" "$APP_PATH/entitlements.plist" 2>/dev/null || true
        
        # 打包 IPA
        IPA_NAME="PermanentStore_${VERSION}_${BUILD_NUM}.ipa"
        mkdir -p "$IPA_OUTPUT/Payload"
        cp -r "$APP_PATH" "$IPA_OUTPUT/Payload/"
        cd "$IPA_OUTPUT"
        zip -qr "$IPA_NAME" Payload/
        rm -rf Payload
        cd - > /dev/null
        
        echo -e "${GREEN}  ✅ IPA 生成成功: $IPA_OUTPUT/$IPA_NAME${NC}"
        echo -e "${YELLOW}  ⚠️ IPA 包含动态 Frameworks，需要签名后才能安装${NC}"
    else
        echo -e "${YELLOW}  ⚠️ 未找到编译产物${NC}"
    fi
fi

# ============================================================
# 验证所有产物
# ============================================================
echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}  构建完成！${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""

for fw in OpenSSL PLIST ldid zsign; do
    fw_path="$FRAMEWORKS_OUTPUT/${fw}.framework"
    if [ -d "$fw_path" ]; then
        size=$(du -sh "$fw_path" 2>/dev/null | cut -f1)
        if [ -f "$fw_path/$fw" ]; then
            file "$fw_path/$fw" 2>/dev/null | grep -q "dynamically linked" && type="动态库" || type="静态库"
        else
            type="未知"
        fi
        echo -e "  ${GREEN}✅${NC} $fw.framework ($size, $type)"
    else
        echo -e "  ${RED}❌${NC} $fw.framework (缺失)"
    fi
done

echo ""
if ls "$IPA_OUTPUT"/*.ipa 2>/dev/null; then
    echo -e "📱 IPA: $(ls "$IPA_OUTPUT"/*.ipa 2>/dev/null)"
fi
echo -e "🔐 Entitlements: $ENTITLEMENTS_FILE"
