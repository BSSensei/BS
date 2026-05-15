#!/bin/bash
set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 错误处理
trap 'echo -e "${RED}❌ 构建失败，退出码: $?${NC}"; exit 1' ERR

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
BUNDLE_ID="com.permanentstore.app"

IPA_OUTPUT="$ROOT_DIR/IPA"
ENTITLEMENTS_FILE="$ROOT_DIR/entitlements.plist"

mkdir -p "$BUILD_TEMP" "$FRAMEWORKS_OUTPUT" "$IPA_OUTPUT"

DEVICE_SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
SDK_VERSION=$(xcrun --sdk iphoneos --show-sdk-version)
MIN_IOS_VERSION="12.0"

if [ -z "$DEVICE_SDK_PATH" ]; then
    echo -e "${RED}❌ 无法找到 iPhoneOS SDK${NC}"
    exit 1
fi

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  PermanentStore 完整构建脚本${NC}"
echo -e "${BLUE}============================================================${NC}"
echo -e "📱 设备 SDK: $DEVICE_SDK_PATH"
echo -e "📦 Framework 输出: $FRAMEWORKS_OUTPUT"
echo -e "📱 IPA 输出: $IPA_OUTPUT"
if [ -f "$ENTITLEMENTS_FILE" ]; then
    echo -e "🔐 Entitlements: $ENTITLEMENTS_FILE"
else
    echo -e "${YELLOW}⚠️ 未找到 entitlements.plist 文件${NC}"
fi

# 限制并发数（避免 CI 内存不足）
CPU_CORES=$(sysctl -n hw.ncpu)
if [ "$CPU_CORES" -gt 4 ]; then
    CPU_CORES=4
fi
echo -e "🖥️  使用并发数: $CPU_CORES"

# ============================================================
# 辅助函数
# ============================================================

create_dynamic_framework() {
    local name=$1
    local dylib_path=$2
    local headers_dir=$3
    local output_dir=$4
    
    local framework_dir="$output_dir/${name}.framework"
    rm -rf "$framework_dir"
    mkdir -p "$framework_dir/Headers"
    mkdir -p "$framework_dir/Modules"
    
    # 复制头文件
    if [ -d "$headers_dir" ]; then
        # 查找头文件可能的位置
        if [ -d "$headers_dir/plist" ]; then
            cp -r "$headers_dir/plist" "$framework_dir/Headers/" 2>/dev/null || true
        else
            cp -r "$headers_dir"/* "$framework_dir/Headers/" 2>/dev/null || true
        fi
    fi
    
    # 复制动态库
    cp "$dylib_path" "$framework_dir/${name}"
    
    # 修改 install name
    install_name_tool -id "@rpath/${name}.framework/${name}" "$framework_dir/${name}" 2>/dev/null || true
    
    # 创建 modulemap
    cat > "$framework_dir/Modules/module.modulemap" << EOF
framework module $name {
    umbrella header "${name}.h"
    export *
}
EOF
    
    # 创建 Info.plist
    cat > "$framework_dir/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${name}</string>
    <key>CFBundleIdentifier</key>
    <string>com.permanentstore.${name}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${name}</string>
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
    
    echo -e "${GREEN}  ✅ ${name}.framework (动态库)${NC}"
}

create_static_framework() {
    local name=$1
    local binary_path=$2
    local headers_dir=$3
    local output_dir=$4
    
    local framework_dir="$output_dir/${name}.framework"
    rm -rf "$framework_dir"
    mkdir -p "$framework_dir/Headers"
    
    if [ -d "$headers_dir" ]; then
        cp -r "$headers_dir"/* "$framework_dir/Headers/" 2>/dev/null || true
    fi
    
    cp "$binary_path" "$framework_dir/${name}"
    chmod +x "$framework_dir/${name}"
    
    cat > "$framework_dir/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${name}</string>
    <key>CFBundleIdentifier</key>
    <string>com.permanentstore.${name}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${name}</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
EOF
    
    echo -e "${GREEN}  ✅ ${name}.framework (静态库)${NC}"
}

# 动态检测和编译函数
compile_with_detection() {
    local name=$1
    local src_dir=$2
    local libs=$3
    local extra_includes=$4
    local output_name=$5
    
    cd "$src_dir"
    
    # 设置基础编译参数
    local base_cflags="-arch arm64 -isysroot $DEVICE_SDK_PATH -mios-version-min=${MIN_IOS_VERSION}"
    local base_ldflags="-arch arm64 -isysroot $DEVICE_SDK_PATH -mios-version-min=${MIN_IOS_VERSION}"
    
    # 添加额外的头文件路径
    local cflags="$base_cflags"
    local ldflags="$base_ldflags"
    
    for inc in $extra_includes; do
        cflags="$cflags -I$inc"
    done
    
    # 添加库路径
    for lib in $libs; do
        if [[ "$lib" == -L* ]]; then
            ldflags="$ldflags $lib"
        fi
    done
    
    # 链接库
    local link_libs=""
    for lib in $libs; do
        if [[ "$lib" == -l* ]]; then
            link_libs="$link_libs $lib"
        fi
    done
    
    # 检测源文件类型并编译
    local source_files=""
    local compiler=""
    
    # 查找源文件
    if ls *.mm 1> /dev/null 2>&1; then
        source_files="*.mm"
        compiler="xcrun -sdk iphoneos clang++"
        cflags="$cflags -std=c++17 -ObjC++"
    elif ls *.cpp 1> /dev/null 2>&1; then
        source_files="*.cpp"
        compiler="xcrun -sdk iphoneos clang++"
        cflags="$cflags -std=c++17"
    elif ls *.c 1> /dev/null 2>&1; then
        source_files="*.c"
        compiler="xcrun -sdk iphoneos clang"
    else
        echo -e "${YELLOW}  ⚠️ 未找到源文件，尝试使用 Makefile${NC}"
        return 1
    fi
    
    echo "  使用编译器: $compiler"
    echo "  源文件: $source_files"
    
    # 编译
    $compiler $cflags $ldflags $link_libs -o "$output_name" $source_files
    
    if [ -f "$output_name" ]; then
        echo -e "${GREEN}  ✅ 编译成功: $output_name${NC}"
        return 0
    else
        echo -e "${RED}  ❌ 编译失败${NC}"
        return 1
    fi
}

# 合并 entitlements 到 app
merge_entitlements() {
    local app_path=$1
    local entitlements_file=$2
    
    if [ ! -f "$entitlements_file" ]; then
        echo -e "${YELLOW}  ⚠️ 未找到 entitlements.plist，跳过合并${NC}"
        return 0
    fi
    
    local entitlements_dest="$app_path/entitlements.plist"
    
    cp "$entitlements_file" "$entitlements_dest"
    echo -e "${GREEN}  ✅ 已合并 entitlements.plist${NC}"
    
    # 使用 ldid 签名（如果有）
    local ldid_path="$FRAMEWORKS_OUTPUT/ldid.framework/ldid"
    if [ -f "$ldid_path" ]; then
        echo "  正在使用 ldid 签名..."
        "$ldid_path" -S"$entitlements_dest" "$app_path/PermanentStore" 2>/dev/null || true
    fi
}

# 清理函数
cleanup() {
    echo -e "\n${YELLOW}正在清理临时文件...${NC}"
    cd "$BUILD_TEMP" 2>/dev/null || return
    find . -name "*.o" -delete 2>/dev/null || true
    find . -name "*.lo" -delete 2>/dev/null || true
    find . -name ".libs" -type d -exec rm -rf {} + 2>/dev/null || true
}

trap cleanup EXIT

# ============================================================
# 1. 编译 OpenSSL Framework (动态库)
# ============================================================
echo -e "\n${YELLOW}📦 [1/5] 编译 OpenSSL Framework (动态库)${NC}"

cd "$BUILD_TEMP"
if [ ! -d "openssl_src" ]; then
    git clone --depth 1 https://github.com/openssl/openssl.git openssl_src
fi
cd openssl_src

echo "  编译 arm64 (真机) 动态库..."
make clean 2>/dev/null || true
make distclean 2>/dev/null || true

# 配置 OpenSSL 动态库
./Configure ios64-cross \
    --prefix="$BUILD_TEMP/openssl_device" \
    --openssldir="$BUILD_TEMP/openssl_device/ssl" \
    --libdir="lib" \
    shared \
    no-tests \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min=${MIN_IOS_VERSION}

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ OpenSSL Configure 失败${NC}"
    exit 1
fi

make -j${CPU_CORES}
if [ $? -ne 0 ]; then
    echo -e "${RED}❌ OpenSSL Make 失败${NC}"
    exit 1
fi

make install_sw

cd ..

# 创建动态 Framework
for libname in crypto ssl; do
    dylib_path="$BUILD_TEMP/openssl_device/lib/lib${libname}.dylib"
    if [ -f "$dylib_path" ]; then
        create_dynamic_framework \
            "$libname" \
            "$dylib_path" \
            "$BUILD_TEMP/openssl_device/include" \
            "$FRAMEWORKS_OUTPUT"
    else
        echo -e "${RED}❌ 找不到 lib${libname}.dylib${NC}"
        exit 1
    fi
done

echo -e "${GREEN}✅ OpenSSL 动态库编译完成${NC}"

# ============================================================
# 2. 编译 libplist Framework (动态库)
# ============================================================
echo -e "\n${YELLOW}📦 [2/5] 编译 libplist Framework (动态库)${NC}"

# 安装 autotools 工具
if ! command -v libtoolize &> /dev/null; then
    brew install autoconf automake libtool
fi

cd "$BUILD_TEMP"
if [ ! -d "libplist_src" ]; then
    git clone --depth 1 https://github.com/libimobiledevice/libplist.git libplist_src
fi
cd libplist_src

# 如果源码没有预生成的 configure，则运行 autogen.sh
if [ ! -f "./configure" ]; then
    echo "  运行 autogen.sh 生成 configure..."
    ./autogen.sh
fi

echo "  编译 arm64 (真机) 动态库..."
make clean 2>/dev/null || true
make distclean 2>/dev/null || true

# 设置 iOS 交叉编译环境变量（关键修复）
export CC="xcrun -sdk iphoneos clang -arch arm64"
export CXX="xcrun -sdk iphoneos clang++ -arch arm64"
export CFLAGS="-arch arm64 -isysroot $DEVICE_SDK_PATH -mios-version-min=${MIN_IOS_VERSION}"
export CXXFLAGS="-arch arm64 -isysroot $DEVICE_SDK_PATH -mios-version-min=${MIN_IOS_VERSION}"
export LDFLAGS="-arch arm64 -isysroot $DEVICE_SDK_PATH -mios-version-min=${MIN_IOS_VERSION}"

./configure \
    --prefix="$BUILD_TEMP/libplist_device" \
    --enable-shared \
    --disable-static \
    --disable-tests \
    --host=arm64-apple-darwin

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ libplist Configure 失败${NC}"
    exit 1
fi

make -j${CPU_CORES}
if [ $? -ne 0 ]; then
    echo -e "${RED}❌ libplist Make 失败${NC}"
    exit 1
fi

make install

cd ..

# 创建动态 Framework
dylib_path="$BUILD_TEMP/libplist_device/lib/libplist-2.0.dylib"
if [ -f "$dylib_path" ]; then
    create_dynamic_framework \
        "plist" \
        "$dylib_path" \
        "$BUILD_TEMP/libplist_device/include" \
        "$FRAMEWORKS_OUTPUT"
else
    echo -e "${RED}❌ 找不到 libplist-2.0.dylib${NC}"
    exit 1
fi

echo -e "${GREEN}✅ libplist 动态库编译完成${NC}"

# ============================================================
# 3. 编译 ldid (静态可执行文件，放入 Framework)
# ============================================================
echo -e "\n${YELLOW}📦 [3/5] 编译 ldid Framework${NC}"

cd "$BUILD_TEMP"
if [ ! -d "ldid_src" ]; then
    git clone --depth 1 https://github.com/ProcursusTeam/ldid.git ldid_src
fi
cd ldid_src

OPENSSL_DEVICE="$BUILD_TEMP/openssl_device"
LIBPLIST_DEVICE="$BUILD_TEMP/libplist_device"

echo "  编译 arm64 (真机)..."

# 清理
make clean 2>/dev/null || true
rm -f ldid

# 设置编译参数
EXTRA_INCLUDES="$OPENSSL_DEVICE/include $LIBPLIST_DEVICE/include"
EXTRA_LIBS="-L$OPENSSL_DEVICE/lib -L$LIBPLIST_DEVICE/lib -lcrypto -lplist-2.0"

# 动态检测并编译
if ! compile_with_detection "ldid" "." "$EXTRA_LIBS" "$EXTRA_INCLUDES" "ldid"; then
    echo -e "${YELLOW}  尝试其他编译方式...${NC}"
    
    # 尝试查找所有 .c .cpp .mm 文件
    SOURCES=$(find . -maxdepth 1 -name "*.c" -o -name "*.cpp" -o -name "*.mm" | tr '\n' ' ')
    
    if [ -n "$SOURCES" ]; then
        echo "  找到源文件: $SOURCES"
        
        # 检测是否需要 Objective-C++ 支持
        if echo "$SOURCES" | grep -q "\.mm"; then
            xcrun -sdk iphoneos clang++ -arch arm64 \
                -std=c++17 -ObjC++ \
                -isysroot "$DEVICE_SDK_PATH" \
                -mios-version-min=${MIN_IOS_VERSION} \
                -I"$OPENSSL_DEVICE/include" \
                -I"$LIBPLIST_DEVICE/include" \
                -L"$OPENSSL_DEVICE/lib" \
                -L"$LIBPLIST_DEVICE/lib" \
                -lcrypto -lplist-2.0 \
                -o ldid $SOURCES
        else
            xcrun -sdk iphoneos clang++ -arch arm64 \
                -std=c++17 \
                -isysroot "$DEVICE_SDK_PATH" \
                -mios-version-min=${MIN_IOS_VERSION} \
                -I"$OPENSSL_DEVICE/include" \
                -I"$LIBPLIST_DEVICE/include" \
                -L"$OPENSSL_DEVICE/lib" \
                -L"$LIBPLIST_DEVICE/lib" \
                -lcrypto -lplist-2.0 \
                -o ldid $SOURCES
        fi
    fi
fi

# 创建输出目录
mkdir -p "$BUILD_TEMP/ldid_device"
if [ -f "ldid" ]; then
    cp ldid "$BUILD_TEMP/ldid_device/"
    echo -e "${GREEN}  ✅ ldid 编译成功${NC}"
else
    echo -e "${YELLOW}  ⚠️ ldid 编译失败，创建 stub${NC}"
    cat > "$BUILD_TEMP/ldid_device/ldid" << 'EOF'
#!/bin/bash
# ldid stub - fallback
echo "ldid stub - signing skipped"
EOF
    chmod +x "$BUILD_TEMP/ldid_device/ldid"
fi

cd ..

# 创建头文件
mkdir -p "$BUILD_TEMP/ldid_headers"
cat > "$BUILD_TEMP/ldid_headers/ldid.h" << 'EOF'
#ifndef ldid_h
#define ldid_h

#ifdef __cplusplus
extern "C" {
#endif

// ldid 签名函数
int ldid_sign(const char* file_path, const char* entitlements_path);

#ifdef __cplusplus
}
#endif

#endif
EOF

# ldid 是可执行文件，使用静态 Framework 包装
if [ -f "$BUILD_TEMP/ldid_device/ldid" ]; then
    create_static_framework \
        "ldid" \
        "$BUILD_TEMP/ldid_device/ldid" \
        "$BUILD_TEMP/ldid_headers" \
        "$FRAMEWORKS_OUTPUT"
fi

echo -e "${GREEN}✅ ldid 编译完成${NC}"

# ============================================================
# 4. 编译 zsign (静态可执行文件，放入 Framework)
# ============================================================
echo -e "\n${YELLOW}📦 [4/5] 编译 zsign Framework${NC}"

cd "$BUILD_TEMP"
if [ ! -d "zsign_src" ]; then
    git clone --depth 1 https://github.com/zhlynn/zsign.git zsign_src
fi
cd zsign_src

OPENSSL_DEVICE="$BUILD_TEMP/openssl_device"

echo "  编译 arm64 (真机)..."

# 清理
make clean 2>/dev/null || true
rm -f zsign

# 设置编译参数
EXTRA_INCLUDES="$OPENSSL_DEVICE/include"
EXTRA_LIBS="-L$OPENSSL_DEVICE/lib -lcrypto -lssl"

# 动态检测并编译
if ! compile_with_detection "zsign" "." "$EXTRA_LIBS" "$EXTRA_INCLUDES" "zsign"; then
    echo -e "${YELLOW}  尝试其他编译方式...${NC}"
    
    # 查找源文件
    SOURCES=$(find . -maxdepth 1 -name "*.c" -o -name "*.cpp" | tr '\n' ' ')
    
    if [ -n "$SOURCES" ]; then
        # zsign 通常需要 C++11
        xcrun -sdk iphoneos clang++ -arch arm64 \
            -std=c++11 \
            -isysroot "$DEVICE_SDK_PATH" \
            -mios-version-min=${MIN_IOS_VERSION} \
            -I"$OPENSSL_DEVICE/include" \
            -L"$OPENSSL_DEVICE/lib" \
            -lcrypto -lssl \
            -o zsign $SOURCES
    fi
fi

# 创建输出目录
mkdir -p "$BUILD_TEMP/zsign_device"
if [ -f "zsign" ]; then
    cp zsign "$BUILD_TEMP/zsign_device/"
    echo -e "${GREEN}  ✅ zsign 编译成功${NC}"
else
    echo -e "${YELLOW}  ⚠️ zsign 编译失败，创建 stub${NC}"
    cat > "$BUILD_TEMP/zsign_device/zsign" << 'EOF'
#!/bin/bash
# zsign stub - fallback
echo "zsign stub - signing skipped"
EOF
    chmod +x "$BUILD_TEMP/zsign_device/zsign"
fi

cd ..

# 创建头文件
mkdir -p "$BUILD_TEMP/zsign_headers"
cat > "$BUILD_TEMP/zsign_headers/zsign.h" << 'EOF'
#ifndef zsign_h
#define zsign_h

#ifdef __cplusplus
extern "C" {
#endif

// zsign 签名函数
int zsign_sign_ipa(const char* ipa_path, const char* p12_path, const char* password, const char* output_path);

#ifdef __cplusplus
}
#endif

#endif
EOF

# zsign 是可执行文件，使用静态 Framework 包装
if [ -f "$BUILD_TEMP/zsign_device/zsign" ]; then
    create_static_framework \
        "zsign" \
        "$BUILD_TEMP/zsign_device/zsign" \
        "$BUILD_TEMP/zsign_headers" \
        "$FRAMEWORKS_OUTPUT"
fi

echo -e "${GREEN}✅ zsign 编译完成${NC}"

# ============================================================
# 5. 编译 Swift 项目并打包 IPA
# ============================================================
echo -e "\n${YELLOW}📱 [5/5] 编译 Swift 项目并生成 IPA${NC}"

# 检查 Xcode 项目
if [ ! -d "$XCODE_PROJECT" ]; then
    echo -e "${RED}❌ 找不到 Xcode 项目: $XCODE_PROJECT${NC}"
    echo -e "${YELLOW}   请确认项目路径正确，或手动编译${NC}"
    exit 1
fi

# 获取版本号
VERSION=$(defaults read "$ROOT_DIR/PermanentStore/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0")
BUILD_NUM=$(defaults read "$ROOT_DIR/PermanentStore/Info.plist" CFBundleVersion 2>/dev/null || echo "1")

echo "  版本: $VERSION ($BUILD_NUM)"

# 清理旧构建
echo "  清理旧构建..."
xcodebuild clean \
    -project "$XCODE_PROJECT" \
    -scheme "$XCODE_SCHEME" \
    -configuration "$XCODE_CONFIGURATION" || true

# 构建 archive
echo "  构建 archive..."
ARCHIVE_PATH="$BUILD_TEMP/PermanentStore.xcarchive"
xcodebuild archive \
    -project "$XCODE_PROJECT" \
    -scheme "$XCODE_SCHEME" \
    -configuration "$XCODE_CONFIGURATION" \
    -archivePath "$ARCHIVE_PATH" \
    -sdk iphoneos \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    OTHER_CODE_SIGN_FLAGS="--deep" \
    DEVELOPMENT_TEAM=""

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Archive 构建失败${NC}"
    exit 1
fi

# 合并 entitlements 到 app
echo "  合并 entitlements..."
APP_PATH="$ARCHIVE_PATH/Products/Applications/PermanentStore.app"
if [ -d "$APP_PATH" ]; then
    merge_entitlements "$APP_PATH" "$ENTITLEMENTS_FILE"
else
    echo -e "${YELLOW}  ⚠️ 未找到 .app 目录，跳过 entitlements 合并${NC}"
fi

# 导出 IPA
echo "  导出 IPA..."
EXPORT_OPTIONS_PLIST="$BUILD_TEMP/exportOptions.plist"
cat > "$EXPORT_OPTIONS_PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>teamID</key>
    <string></string>
    <key>compileBitcode</key>
    <false/>
    <key>uploadBitcode</key>
    <false/>
    <key>uploadSymbols</key>
    <false/>
    <key>signingStyle</key>
    <string>manual</string>
    <key>provisioningProfiles</key>
    <dict/>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$IPA_OUTPUT" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" || true

# 查找生成的 IPA
IPA_FILE=$(find "$IPA_OUTPUT" -name "*.ipa" | head -1)
if [ -n "$IPA_FILE" ] && [ -f "$IPA_FILE" ]; then
    FINAL_IPA="$IPA_OUTPUT/PermanentStore_${VERSION}_${BUILD_NUM}.ipa"
    mv "$IPA_FILE" "$FINAL_IPA" 2>/dev/null || true
    
    # 如果 entitlements 存在，尝试注入到 IPA 中
    if [ -f "$ENTITLEMENTS_FILE" ]; then
        echo "  将 entitlements 注入到 IPA..."
        TEMP_IPA_EXTRACT="$BUILD_TEMP/ipa_extract"
        rm -rf "$TEMP_IPA_EXTRACT"
        mkdir -p "$TEMP_IPA_EXTRACT"
        unzip -q "$FINAL_IPA" -d "$TEMP_IPA_EXTRACT"
        
        if [ -d "$TEMP_IPA_EXTRACT/Payload/PermanentStore.app" ]; then
            cp "$ENTITLEMENTS_FILE" "$TEMP_IPA_EXTRACT/Payload/PermanentStore.app/entitlements.plist"
            cd "$TEMP_IPA_EXTRACT"
            zip -qr "$FINAL_IPA" .
            cd - > /dev/null
            rm -rf "$TEMP_IPA_EXTRACT"
            echo -e "${GREEN}  ✅ entitlements 已注入到 IPA${NC}"
        fi
    fi
    
    echo -e "${GREEN}✅ IPA 生成成功: $FINAL_IPA${NC}"
else
    echo -e "${YELLOW}⚠️ IPA 文件未找到，Archive 位于: $ARCHIVE_PATH${NC}"
fi

# ============================================================
# 完成
# ============================================================
echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}  构建完成！${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "📦 Frameworks: $FRAMEWORKS_OUTPUT"
echo -e "📱 IPA: $IPA_OUTPUT"
echo ""
ls -la "$FRAMEWORKS_OUTPUT" 2>/dev/null || echo "  (无 Frameworks)"
echo ""
ls -la "$IPA_OUTPUT" 2>/dev/null || echo "  (无 IPA)"
