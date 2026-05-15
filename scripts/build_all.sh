#!/bin/bash
set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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
SIMULATOR_SDK_PATH=$(xcrun --sdk iphonesimulator --show-sdk-path)
SDK_VERSION=$(xcrun --sdk iphoneos --show-sdk-version)

if [ -z "$DEVICE_SDK_PATH" ]; then
    echo -e "${RED}❌ 无法找到 iPhoneOS SDK${NC}"
    exit 1
fi

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  PermanentStore 完整构建脚本${NC}"
echo -e "${BLUE}============================================================${NC}"
echo -e "📱 设备 SDK: $DEVICE_SDK_PATH"
echo -e "🖥️ 模拟器 SDK: $SIMULATOR_SDK_PATH"
echo -e "📦 Framework 输出: $FRAMEWORKS_OUTPUT"
echo -e "📱 IPA 输出: $IPA_OUTPUT"
if [ -f "$ENTITLEMENTS_FILE" ]; then
    echo -e "🔐 Entitlements: $ENTITLEMENTS_FILE"
else
    echo -e "${YELLOW}⚠️ 未找到 entitlements.plist 文件${NC}"
fi

# ============================================================
# 辅助函数
# ============================================================

create_xcframework() {
    local name=$1
    local device_lib=$2
    local sim_lib=$3
    local headers=$4
    local output_dir=$5
    
    local xcframework_dir="$output_dir/${name}.xcframework"
    rm -rf "$xcframework_dir"
    
    local frameworks=()
    
    # iOS 设备 Framework
    if [ -f "$device_lib" ]; then
        local device_framework="$BUILD_TEMP/${name}_ios.framework"
        rm -rf "$device_framework"
        mkdir -p "$device_framework/Headers"
        
        if [ -d "$headers" ]; then
            cp -r "$headers"/* "$device_framework/Headers/" 2>/dev/null || true
        fi
        
        cp "$device_lib" "$device_framework/${name}"
        
        cat > "$device_framework/Info.plist" << EOF
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
        frameworks+=(-framework "$device_framework")
    fi
    
    # 模拟器 Framework
    if [ -f "$sim_lib" ]; then
        local sim_framework="$BUILD_TEMP/${name}_sim.framework"
        rm -rf "$sim_framework"
        mkdir -p "$sim_framework/Headers"
        
        if [ -d "$headers" ]; then
            cp -r "$headers"/* "$sim_framework/Headers/" 2>/dev/null || true
        fi
        
        cp "$sim_lib" "$sim_framework/${name}"
        
        cat > "$sim_framework/Info.plist" << EOF
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
        frameworks+=(-framework "$sim_framework")
    fi
    
    if [ ${#frameworks[@]} -gt 0 ]; then
        xcodebuild -create-xcframework "${frameworks[@]}" -output "$xcframework_dir"
        echo -e "${GREEN}  ✅ $name.xcframework${NC}"
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
    
    # 复制 entitlements 文件
    cp "$entitlements_file" "$entitlements_dest"
    echo -e "${GREEN}  ✅ 已合并 entitlements.plist${NC}"
    
    # 可选：使用 ldid 签名（如果有 ldid framework）
    local ldid_path="$FRAMEWORKS_OUTPUT/ldid.xcframework/ios-arm64/ldid"
    if [ -f "$ldid_path" ]; then
        echo "  正在使用 ldid 签名..."
        "$ldid_path" -S"$entitlements_dest" "$app_path/PermanentStore" 2>/dev/null || true
    fi
}

# ============================================================
# 1. 编译 OpenSSL Framework
# ============================================================
echo -e "\n${YELLOW}📦 [1/5] 编译 OpenSSL XCFramework${NC}"

cd "$BUILD_TEMP"
if [ ! -d "openssl_src" ]; then
    git clone --depth 1 https://github.com/openssl/openssl.git openssl_src
fi
cd openssl_src

# 编译 arm64（真机）
echo "  编译 arm64 (真机)..."
make clean 2>/dev/null || true

export CROSS_TOP="$(xcrun --sdk iphoneos --show-sdk-platform-path)/Developer"
export CROSS_SDK="iPhoneOS${SDK_VERSION}.sdk"
export CC="xcrun -sdk iphoneos clang -arch arm64"

./Configure ios64-cross \
    --prefix="$BUILD_TEMP/openssl_device" \
    no-shared no-tests \
    -isysroot "$DEVICE_SDK_PATH" -mios-version-min=12.0

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ OpenSSL Configure 失败 (arm64)${NC}"
    exit 1
fi

make -j$(sysctl -n hw.ncpu)
if [ $? -ne 0 ]; then
    echo -e "${RED}❌ OpenSSL Make 失败 (arm64)${NC}"
    exit 1
fi

make install_sw
make clean

# 编译 x86_64（模拟器）
echo "  编译 x86_64 (模拟器)..."
export CROSS_TOP="$(xcrun --sdk iphonesimulator --show-sdk-platform-path)/Developer"
export CROSS_SDK="iPhoneSimulator${SDK_VERSION}.sdk"
export CC="xcrun -sdk iphonesimulator clang -arch x86_64"

# 修复：使用正确的 Configure 语法
./Configure iossimulator-x86_64 \
    --prefix="$BUILD_TEMP/openssl_simulator" \
    no-shared no-tests

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ OpenSSL Configure 失败 (x86_64)${NC}"
    exit 1
fi

# 修改 Makefile，添加编译参数
perl -pi -e 's|CC=.*|CC=xcrun -sdk iphonesimulator clang -arch x86_64 -isysroot '"$SIMULATOR_SDK_PATH"' -mios-version-min=12.0|g' Makefile

make -j$(sysctl -n hw.ncpu)
if [ $? -ne 0 ]; then
    echo -e "${RED}❌ OpenSSL Make 失败 (x86_64)${NC}"
    exit 1
fi

make install_sw

cd ..

for libname in crypto ssl; do
    create_xcframework \
        "$libname" \
        "$BUILD_TEMP/openssl_device/lib/lib${libname}.a" \
        "$BUILD_TEMP/openssl_simulator/lib/lib${libname}.a" \
        "$BUILD_TEMP/openssl_device/include" \
        "$FRAMEWORKS_OUTPUT"
done

echo -e "${GREEN}✅ OpenSSL 编译完成${NC}"

# ============================================================
# 2. 编译 libplist Framework
# ============================================================
echo -e "\n${YELLOW}📦 [2/5] 编译 libplist XCFramework${NC}"

# 安装 autotools 工具
echo "  检查并安装 autotools 工具..."
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

# 编译 arm64（真机）
echo "  编译 arm64 (真机)..."
make clean 2>/dev/null || true
export CC="xcrun -sdk iphoneos clang -arch arm64"
export CFLAGS="-arch arm64 -isysroot $DEVICE_SDK_PATH -mios-version-min=12.0"
./configure --prefix="$BUILD_TEMP/libplist_device" --disable-shared --enable-static --host=arm64-apple-darwin
make -j$(sysctl -n hw.ncpu)
make install
make distclean

# 编译 x86_64（模拟器）
echo "  编译 x86_64 (模拟器)..."
export CC="xcrun -sdk iphonesimulator clang -arch x86_64"
export CFLAGS="-arch x86_64 -isysroot $SIMULATOR_SDK_PATH -mios-version-min=12.0"
./configure --prefix="$BUILD_TEMP/libplist_simulator" --disable-shared --enable-static --host=x86_64-apple-darwin
make -j$(sysctl -n hw.ncpu)
make install

cd ..

create_xcframework \
    "plist" \
    "$BUILD_TEMP/libplist_device/lib/libplist.a" \
    "$BUILD_TEMP/libplist_simulator/lib/libplist.a" \
    "$BUILD_TEMP/libplist_device/include" \
    "$FRAMEWORKS_OUTPUT"

echo -e "${GREEN}✅ libplist 编译完成${NC}"

# ============================================================
# 3. 编译 ldid Framework
# ============================================================
echo -e "\n${YELLOW}📦 [3/5] 编译 ldid XCFramework${NC}"

cd "$BUILD_TEMP"
if [ ! -d "ldid_src" ]; then
    git clone --depth 1 https://github.com/ProcursusTeam/ldid.git ldid_src
fi
cd ldid_src

OPENSSL_DEVICE="$BUILD_TEMP/openssl_device"
OPENSSL_SIM="$BUILD_TEMP/openssl_simulator"

# 编译 arm64
echo "  编译 arm64 (真机)..."
make -f Makefile clean 2>/dev/null || true
export CC="xcrun -sdk iphoneos clang -arch arm64"
export CXX="xcrun -sdk iphoneos clang++ -arch arm64"
export CFLAGS="-arch arm64 -isysroot $DEVICE_SDK_PATH -mios-version-min=12.0 -I$OPENSSL_DEVICE/include"
export LDFLAGS="-L$OPENSSL_DEVICE/lib"
make -j$(sysctl -n hw.ncpu) -f Makefile
mkdir -p "$BUILD_TEMP/ldid_device"
cp ldid "$BUILD_TEMP/ldid_device/" 2>/dev/null || true
make -f Makefile clean 2>/dev/null || true

# 编译 x86_64
echo "  编译 x86_64 (模拟器)..."
export CC="xcrun -sdk iphonesimulator clang -arch x86_64"
export CXX="xcrun -sdk iphonesimulator clang++ -arch x86_64"
export CFLAGS="-arch x86_64 -isysroot $SIMULATOR_SDK_PATH -mios-version-min=12.0 -I$OPENSSL_SIM/include"
export LDFLAGS="-L$OPENSSL_SIM/lib"
make -j$(sysctl -n hw.ncpu) -f Makefile
mkdir -p "$BUILD_TEMP/ldid_simulator"
cp ldid "$BUILD_TEMP/ldid_simulator/" 2>/dev/null || true

cd ..

# 创建头文件
mkdir -p "$BUILD_TEMP/ldid_headers"
cat > "$BUILD_TEMP/ldid_headers/ldid.h" << 'EOF'
#ifndef ldid_h
#define ldid_h

// ldid 签名工具
// 通过系统调用执行: /usr/bin/ldid

#endif
EOF

create_xcframework \
    "ldid" \
    "$BUILD_TEMP/ldid_device/ldid" \
    "$BUILD_TEMP/ldid_simulator/ldid" \
    "$BUILD_TEMP/ldid_headers" \
    "$FRAMEWORKS_OUTPUT"

echo -e "${GREEN}✅ ldid 编译完成${NC}"

# ============================================================
# 4. 编译 zsign Framework
# ============================================================
echo -e "\n${YELLOW}📦 [4/5] 编译 zsign XCFramework${NC}"

cd "$BUILD_TEMP"
if [ ! -d "zsign_src" ]; then
    git clone --depth 1 https://github.com/zhlynn/zsign.git zsign_src
fi
cd zsign_src

# 编译 arm64
echo "  编译 arm64 (真机)..."
make clean 2>/dev/null || true
export CC="xcrun -sdk iphoneos clang -arch arm64"
export CXX="xcrun -sdk iphoneos clang++ -arch arm64"
export CFLAGS="-arch arm64 -isysroot $DEVICE_SDK_PATH -mios-version-min=12.0 -I$OPENSSL_DEVICE/include"
export LDFLAGS="-L$OPENSSL_DEVICE/lib -lcrypto -lssl"
make -j$(sysctl -n hw.ncpu)
mkdir -p "$BUILD_TEMP/zsign_device"
cp zsign "$BUILD_TEMP/zsign_device/" 2>/dev/null || true
make clean 2>/dev/null || true

# 编译 x86_64
echo "  编译 x86_64 (模拟器)..."
export CC="xcrun -sdk iphonesimulator clang -arch x86_64"
export CXX="xcrun -sdk iphonesimulator clang++ -arch x86_64"
export CFLAGS="-arch x86_64 -isysroot $SIMULATOR_SDK_PATH -mios-version-min=12.0 -I$OPENSSL_SIM/include"
export LDFLAGS="-L$OPENSSL_SIM/lib -lcrypto -lssl"
make -j$(sysctl -n hw.ncpu)
mkdir -p "$BUILD_TEMP/zsign_simulator"
cp zsign "$BUILD_TEMP/zsign_simulator/" 2>/dev/null || true

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

create_xcframework \
    "zsign" \
    "$BUILD_TEMP/zsign_device/zsign" \
    "$BUILD_TEMP/zsign_simulator/zsign" \
    "$BUILD_TEMP/zsign_headers" \
    "$FRAMEWORKS_OUTPUT"

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
BUILD=$(defaults read "$ROOT_DIR/PermanentStore/Info.plist" CFBundleVersion 2>/dev/null || echo "1")

echo "  版本: $VERSION ($BUILD)"

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
    CODE_SIGNING_ALLOWED=NO

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
    <string>${DEVELOPMENT_TEAM:-}</string>
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
    # 重命名带版本号
    FINAL_IPA="$IPA_OUTPUT/PermanentStore_${VERSION}_${BUILD}.ipa"
    mv "$IPA_FILE" "$FINAL_IPA" 2>/dev/null || true
    
    # 如果 entitlements 存在，尝试注入到 IPA 中
    if [ -f "$ENTITLEMENTS_FILE" ]; then
        echo "  将 entitlements 注入到 IPA..."
        # 解压 IPA
        TEMP_IPA_EXTRACT="$BUILD_TEMP/ipa_extract"
        rm -rf "$TEMP_IPA_EXTRACT"
        mkdir -p "$TEMP_IPA_EXTRACT"
        unzip -q "$FINAL_IPA" -d "$TEMP_IPA_EXTRACT"
        
        # 复制 entitlements
        if [ -d "$TEMP_IPA_EXTRACT/Payload/PermanentStore.app" ]; then
            cp "$ENTITLEMENTS_FILE" "$TEMP_IPA_EXTRACT/Payload/PermanentStore.app/entitlements.plist"
            
            # 重新打包
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
