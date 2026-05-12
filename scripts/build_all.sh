#!/bin/bash
set -e

# ============================================
#  PermanentStore - 编译 OpenSSL + ldid + zsign 为 Frameworks
# ============================================

IOS_MIN="12.0"
ARCH="arm64"
SYSROOT=$(xcrun --sdk iphoneos --show-sdk-path)
echo "✅ SDK: $SYSROOT"

# 编译工具链
CC="xcrun -sdk iphoneos clang -arch ${ARCH} -mios-version-min=${IOS_MIN} -isysroot ${SYSROOT}"
CXX="xcrun -sdk iphoneos clang++ -arch ${ARCH} -mios-version-min=${IOS_MIN} -isysroot ${SYSROOT}"
AR="xcrun -sdk iphoneos ar"
RANLIB="xcrun -sdk iphoneos ranlib"
LIPO="xcrun -sdk iphoneos lipo"

BUILD="$(pwd)/build_temp"
FRAMEWORKS="$(pwd)/Frameworks"
rm -rf "$BUILD" "$FRAMEWORKS"
mkdir -p "$BUILD"

# ======================
# Framework 创建函数
# ======================
create_framework() {
    local name=$1
    local lib_path=$2
    local headers_dir=$3
    
    local fw_dir="$FRAMEWORKS/$name.framework"
    mkdir -p "$fw_dir/Headers"
    
    # 复制二进制
    cp "$lib_path" "$fw_dir/$name"
    
    # 复制头文件
    if [ -d "$headers_dir" ]; then
        cp -r "$headers_dir"/* "$fw_dir/Headers/" 2>/dev/null || true
    fi
    
    # 创建 Info.plist
    cat > "$fw_dir/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$name</string>
    <key>CFBundleIdentifier</key>
    <string>com.permanentstore.$name</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
EOF

    echo "✅ $name.framework 创建完成"
}

# ============================================
# 1. 编译 OpenSSL
# ============================================
echo "📦 编译 OpenSSL..."
cd "$BUILD"
git clone --depth 1 https://github.com/openssl/openssl.git
cd openssl

# 配置
./Configure ios64-cross no-shared no-dso no-asm no-tests no-apps \
    --prefix="$BUILD/openssl_install" \
    -mios-version-min=$IOS_MIN

# ============ 核心修复 ============
CROSS_TOP="$(dirname "$(dirname "$SYSROOT")")"   # .../Platforms/iPhoneOS.platform/Developer
CROSS_SDK="$(basename "$SYSROOT")"                # iPhoneOS18.5.sdk

echo "🔧 修复 Makefile..."
echo "   CROSS_TOP=$CROSS_TOP"
echo "   CROSS_SDK=$CROSS_SDK"

# 修复 Makefile 和所有子目录的 Makefile
find . -name "Makefile" -exec sed -i '' \
    -e "s|^CROSS_TOP=.*|CROSS_TOP=$CROSS_TOP|" \
    -e "s|^CROSS_SDK=.*|CROSS_SDK=$CROSS_SDK|" {} \;

# 暴力兜底：直接替换所有残留的错误路径
find . -name "Makefile" -exec sed -i '' \
    -e "s|-isysroot \"/SDKs/\"|-isysroot \"$SYSROOT\"|g" \
    -e "s|-isysroot /SDKs/|-isysroot $SYSROOT|g" {} \;

# 编译
make -j$(sysctl -n hw.logicalcpu) libcrypto.a libssl.a

echo "✅ OpenSSL 编译完成"

# ============================================
# 2. 编译 ldid
# ============================================
echo "📦 编译 ldid..."
cd "$BUILD"
git clone --depth 1 https://github.com/ProcursusTeam/ldid.git
cd ldid

OBJS=""
for f in *.cpp *.cc; do
    [ ! -f "$f" ] && continue
    [[ "$f" == "main."* ]] && continue
    echo "  $f"
    $CXX -c "$f" -o "${f%.*}.o" \
        -I. \
        -I"$BUILD/openssl/include" \
        -std=c++17 -O2 && OBJS="$OBJS ${f%.*}.o"
done

$AR rcs libldid.a *.o 2>/dev/null
$RANLIB libldid.a

create_framework "ldid" "$(pwd)/libldid.a" "$(pwd)"
cp "$BUILD/openssl/include/openssl" "$FRAMEWORKS/ldid.framework/Headers/" -r 2>/dev/null || true
echo "✅ ldid 完成"

# ============================================
# 3. 编译 zsign
# ============================================
echo "📦 编译 zsign..."
cd "$BUILD"
git clone --depth 1 https://github.com/zhlynn/zsign.git
cd zsign

for f in *.cpp *.cc; do
    [ ! -f "$f" ] && continue
    [[ "$f" == "main."* ]] && continue
    echo "  $f"
    $CXX -c "$f" -o "${f%.*}.o" \
        -I"$BUILD/openssl/include" \
        -I. \
        -std=c++17 -O2
done

$AR rcs libzsign.a *.o
$RANLIB libzsign.a

create_framework "zsign" "$(pwd)/libzsign.a" "$(pwd)"
echo "✅ zsign 完成"

# ============================================
# 4. OpenSSL Framework（合并 libcrypto + libssl）
# ============================================
echo "📦 创建 OpenSSL Framework..."
cd "$BUILD/openssl"

# 合并 libcrypto 和 libssl
$LIPO -create libcrypto.a libssl.a -output libopenssl.a

create_framework "OpenSSL" "$(pwd)/libopenssl.a" "$(pwd)/include"
echo "✅ OpenSSL Framework 完成"

# ============================================
# 结果
# ============================================
echo ""
echo "═══════════════════════════════════════"
echo "✅ 所有 Framework 生成完毕！"
echo "═══════════════════════════════════════"
echo ""
find "$FRAMEWORKS" -name "*.framework" -maxdepth 1 -exec echo "📦 {}" \;
