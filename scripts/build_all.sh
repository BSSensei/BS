#!/bin/bash
set -e

# ============================================
#  PermanentStore - 编译 ldid + zsign 静态库
#  OpenSSL 4.0 交叉编译 iOS arm64
# ============================================

IOS_MIN="12.0"
ARCH="arm64"
SYSROOT=$(xcrun --sdk iphoneos --show-sdk-path)

if [ ! -d "$SYSROOT" ]; then
    echo "❌ 找不到 iPhone SDK"
    exit 1
fi
echo "✅ SDK: $SYSROOT"

CC="xcrun -sdk iphoneos clang -arch ${ARCH} -mios-version-min=${IOS_MIN} -isysroot ${SYSROOT}"
CXX="xcrun -sdk iphoneos clang++ -arch ${ARCH} -mios-version-min=${IOS_MIN} -isysroot ${SYSROOT}"
AR="xcrun -sdk iphoneos ar"
RANLIB="xcrun -sdk iphoneos ranlib"

BUILD_DIR="$(pwd)/build_temp"
OUTPUT_DIR="$(pwd)/Frameworks"

export CROSS_COMPILE=""
export CROSS_TOP="${SYSROOT%/*}"
export CROSS_SDK="${SYSROOT##*/}"

rm -rf "$BUILD_DIR" "$OUTPUT_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR/lib" "$OUTPUT_DIR/include"

# ============================================
# 1. OpenSSL 4.0
# ============================================
build_openssl40() {
    echo "📦 编译 OpenSSL 4.0..."
    cd "$BUILD_DIR"
    
    rm -rf openssl
    git clone --depth 1 --branch OpenSSL_1_0_0-stable https://github.com/openssl/openssl.git openssl 2>/dev/null || true
    
    # 尝试从主分支获取最新 4.0
    if [ ! -f openssl/Configure ]; then
        rm -rf openssl
        git clone --depth 1 https://github.com/openssl/openssl.git
    fi
    cd openssl
    
    ./Configure ios64-cross no-shared no-dso no-asm no-tests no-deprecated \
        --prefix="$OUTPUT_DIR" \
        --openssldir="$OUTPUT_DIR" \
        -mios-version-min=$IOS_MIN \
        2>&1 | tail -2
    
    # 修正 Configure 生成的错误 sysroot 路径
    sed -i '' "s|-isysroot /SDKs/|-isysroot $SYSROOT|g" Makefile 2>/dev/null || true
    
    make -j$(sysctl -n hw.logicalcpu) build_libs 2>&1 | tail -5 || {
        echo "⚠️ build_libs 失败，尝试 build_sw..."
        make -j$(sysctl -n hw.logicalcpu) build_sw 2>&1 | tail -5 || {
            echo "⚠️ 手动编译 libcrypto 和 libssl..."
            make -j$(sysctl -n hw.logicalcpu) libcrypto.a libssl.a 2>&1 | tail -3
        }
    }
    
    make install_sw 2>/dev/null || true
    make install_dev 2>/dev/null || true
    
    # 确保 lib 文件在正确位置
    [ -f libcrypto.a ] && cp libcrypto.a "$OUTPUT_DIR/lib/" || echo "⚠️ libcrypto.a 未找到"
    [ -f libssl.a ] && cp libssl.a "$OUTPUT_DIR/lib/" || echo "⚠️ libssl.a 未找到"
    
    echo "✅ OpenSSL 4.0 完成"
}

# ============================================
# 2. ldid
# ============================================
build_ldid() {
    echo "📦 编译 ldid..."
    cd "$BUILD_DIR"
    
    rm -rf ldid
    git clone --depth 1 https://github.com/ProcursusTeam/ldid.git
    cd ldid
    
    OBJS=""
    for src in *.cpp; do
        [[ "$src" == "main.cpp" ]] && continue
        obj="${src%.cpp}.o"
        echo "  编译: $src"
        $CXX -c "$src" -o "$obj" -I. -std=c++17 -O2 2>&1 | tail -1
        [ -f "$obj" ] && OBJS="$OBJS $obj"
    done
    
    [ -n "$OBJS" ] && $AR rcs "$OUTPUT_DIR/lib/libldid.a" $OBJS && $RANLIB "$OUTPUT_DIR/lib/libldid.a"
    cp *.hpp "$OUTPUT_DIR/include/" 2>/dev/null || true
    cp *.h "$OUTPUT_DIR/include/" 2>/dev/null || true
    
    echo "✅ ldid 完成"
}

# ============================================
# 3. zsign（链 OpenSSL）
# ============================================
build_zsign() {
    echo "📦 编译 zsign..."
    cd "$BUILD_DIR"
    
    rm -rf zsign
    git clone --depth 1 https://github.com/zhlynn/zsign.git
    cd zsign
    
    OBJS=""
    for src in *.cpp; do
        [[ "$src" == "main.cpp" ]] && continue
        obj="${src%.cpp}.o"
        echo "  编译: $src"
        $CXX -c "$src" -o "$obj" \
            -I"$OUTPUT_DIR/include" \
            -I. \
            -std=c++17 -O2 \
            -DHAVE_OPENSSL \
            2>&1 | tail -1
        [ -f "$obj" ] && OBJS="$OBJS $obj"
    done
    
    [ -n "$OBJS" ] && $AR rcs "$OUTPUT_DIR/lib/libzsign.a" $OBJS && $RANLIB "$OUTPUT_DIR/lib/libzsign.a"
    cp *.h "$OUTPUT_DIR/include/" 2>/dev/null || true
    cp *.hpp "$OUTPUT_DIR/include/" 2>/dev/null || true
    
    echo "✅ zsign 完成"
}

# ============================================
echo "🚀 开始编译..."
build_openssl40
build_ldid
build_zsign

echo ""
echo "═══════════════════════════════════════"
echo "✅ 完成！"
echo "═══════════════════════════════════════"
ls -lh "$OUTPUT_DIR/lib/"*.a 2>/dev/null
ls -lh "$OUTPUT_DIR/include/"*.h* 2>/dev/null | head -10
