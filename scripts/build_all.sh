#!/bin/bash
set -e

# ============================================
#  PermanentStore - 编译 OpenSSL + ldid + zsign 为 Frameworks
#  日志文件: build_log.txt
# ============================================

# 日志文件路径
LOG_FILE="$(pwd)/build_log.txt"

# 清空旧日志，记录开始时间
echo "============================================================" | tee "$LOG_FILE"
echo "  PermanentStore 编译日志" | tee -a "$LOG_FILE"
echo "  开始时间: $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"
echo "============================================================" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# 把整个脚本的输出同时写到终端和日志文件
exec > >(tee -a "$LOG_FILE") 2>&1

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

echo "🔧 清理旧构建目录..."
rm -rf "$BUILD" "$FRAMEWORKS"
mkdir -p "$BUILD"
echo ""

# ======================
# Framework 创建函数
# ======================
create_framework() {
    local name=$1
    local lib_path=$2
    local headers_dir=$3
    
    local fw_dir="$FRAMEWORKS/$name.framework"
    mkdir -p "$fw_dir/Headers"
    
    cp "$lib_path" "$fw_dir/$name"
    
    if [ -d "$headers_dir" ]; then
        cp -r "$headers_dir"/* "$fw_dir/Headers/" 2>/dev/null || true
    fi
    
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
    echo ""
}

# ============================================
# 1. 编译 OpenSSL
# ============================================
echo "============================================================"
echo "📦 [1/4] 编译 OpenSSL"
echo "============================================================"
cd "$BUILD"
git clone --depth 1 https://github.com/openssl/openssl.git
cd openssl

echo "🔧 Configure..."
./Configure ios64-cross no-shared no-dso no-asm no-tests no-apps \
    --prefix="$BUILD/openssl_install" \
    -mios-version-min=$IOS_MIN

export CROSS_TOP="$(dirname "$(dirname "$SYSROOT")")"
export CROSS_SDK="$(basename "$SYSROOT")"
export CFLAGS="-isysroot $SYSROOT -mios-version-min=$IOS_MIN -arch $ARCH"
export CXXFLAGS="$CFLAGS"

echo "   CROSS_TOP=$CROSS_TOP"
echo "   CROSS_SDK=$CROSS_SDK"
echo ""

echo "🔨 生成头文件..."
make -j$(sysctl -n hw.logicalcpu) build_generated

echo "🔨 编译 libcrypto.a 和 libssl.a..."
make -j$(sysctl -n hw.logicalcpu) libcrypto.a libssl.a

echo "✅ OpenSSL 编译完成"
echo ""

# ============================================
# 2. 编译 libplist（ldid 依赖）
# ============================================
echo "============================================================"
echo "📦 [2/4] 编译 libplist"
echo "============================================================"
cd "$BUILD"
git clone --depth 1 https://github.com/libimobiledevice/libplist.git
cd libplist

# 生成 configure
if [ -f "autogen.sh" ]; then
    ./autogen.sh 2>/dev/null || true
elif [ -f "configure.ac" ] || [ -f "configure.in" ]; then
    autoreconf -i 2>/dev/null || true
fi

# 如果有 configure 就用 configure，否则手动编译
if [ -f "configure" ]; then
    echo "🔧 Configure..."
    ./configure \
        --host=arm64-apple-ios \
        --prefix="$BUILD/libplist_install" \
        --without-cython \
        CC="$CC" \
        CXX="$CXX" \
        AR="$AR" \
        RANLIB="$RANLIB"
    
    echo "🔨 编译..."
    make -j$(sysctl -n hw.logicalcpu)
    make install
    PLIST_INCLUDE="$BUILD/libplist_install/include"
    PLIST_LIB="$BUILD/libplist_install/lib"
else
    echo "🔧 手动编译..."
    mkdir -p "$BUILD/libplist_install/include/plist"
    cp include/plist/*.h "$BUILD/libplist_install/include/plist/" 2>/dev/null || true
    
    OBJS=""
    for f in src/*.c; do
        [ ! -f "$f" ] && continue
        echo "  $f"
        $CC -c "$f" -o "${f%.*}.o" \
            -Iinclude \
            -DHAVE_CONFIG_H -O2 || continue
        OBJS="$OBJS ${f%.*}.o"
    done
    
    PLIST_INCLUDE="$BUILD/libplist_install/include"
    PLIST_LIB="$(pwd)"
fi

echo "✅ libplist 编译完成"
echo ""

# ============================================
# 3. 编译 ldid
# ============================================
echo "============================================================"
echo "📦 [3/4] 编译 ldid"
echo "============================================================"
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
        -I"$PLIST_INCLUDE" \
        -std=c++17 -O2 && OBJS="$OBJS ${f%.*}.o"
done

echo "🔗 链接 libldid.a..."
$AR rcs libldid.a *.o 2>/dev/null
$RANLIB libldid.a

create_framework "ldid" "$(pwd)/libldid.a" "$(pwd)"
cp "$BUILD/openssl/include/openssl" "$FRAMEWORKS/ldid.framework/Headers/" -r 2>/dev/null || true
echo "✅ ldid 完成"
echo ""

# ============================================
# 4. 编译 zsign
# ============================================
echo "============================================================"
echo "📦 [4/4] 编译 zsign"
echo "============================================================"
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

echo "🔗 链接 libzsign.a..."
$AR rcs libzsign.a *.o
$RANLIB libzsign.a

create_framework "zsign" "$(pwd)/libzsign.a" "$(pwd)"
echo "✅ zsign 完成"
echo ""

# ============================================
# 5. OpenSSL Framework（合并 libcrypto + libssl）
# ============================================
echo "============================================================"
echo "📦 创建 OpenSSL Framework"
echo "============================================================"
cd "$BUILD/openssl"

echo "🔗 合并 libcrypto.a + libssl.a -> libopenssl.a"
$LIPO -create libcrypto.a libssl.a -output libopenssl.a

create_framework "OpenSSL" "$(pwd)/libopenssl.a" "$(pwd)/include"
echo "✅ OpenSSL Framework 完成"
echo ""

# ============================================
# 结果
# ============================================
echo "============================================================"
echo "✅ 所有 Framework 生成完毕！"
echo "============================================================"
echo ""
find "$FRAMEWORKS" -name "*.framework" -maxdepth 1 -exec echo "📦 {}" \;
echo ""

echo "============================================================"
echo "  结束时间: $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"
echo "  日志文件: $LOG_FILE"
echo "============================================================"

# 如果有压缩工具，打包日志
if command -v gzip &> /dev/null; then
    gzip -f "$LOG_FILE"
    echo "📥 日志已压缩: ${LOG_FILE}.gz"
fi
