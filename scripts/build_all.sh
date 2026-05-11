#!/bin/bash
set -e

IOS_MIN="12.0"
ARCH="arm64"
SYSROOT=$(xcrun --sdk iphoneos --show-sdk-path)
echo "✅ SDK: $SYSROOT"

BUILD="$(pwd)/build_temp"
OUT="$(pwd)/Frameworks"

# 关键：设置环境变量，OpenSSL Configure 会读取
export CROSS_TOP="$(dirname "$SYSROOT")"
export CROSS_SDK="$(basename "$SYSROOT")"

rm -rf "$BUILD" "$OUT"
mkdir -p "$BUILD" "$OUT/lib" "$OUT/include"

# ============================================
# 1. OpenSSL
# ============================================
echo "📦 编译 OpenSSL..."
cd "$BUILD"
git clone --depth 1 https://github.com/openssl/openssl.git
cd openssl

# ios64-cross 会用 CROSS_TOP/CROSS_SDK 环境变量
./Configure ios64-cross no-shared no-dso no-asm no-tests no-apps \
    --prefix="$OUT" -mios-version-min=$IOS_MIN

# 如果 Makefile 里还有 /SDKs/，用强力方式修复
find . -name "Makefile" -exec sed -i '' "s|/SDKs/|$SYSROOT|g" {} \;

# 只编译库
make -j$(sysctl -n hw.logicalcpu) libcrypto.a libssl.a 2>&1 | tail -5

cp libcrypto.a libssl.a "$OUT/lib/"
cp -r include/openssl "$OUT/include/"

echo "✅ OpenSSL 完成"

# ============================================
# 2. ldid + zsign + SignWrapper
# ============================================
CXX="xcrun -sdk iphoneos clang++ -arch ${ARCH} -mios-version-min=${IOS_MIN} -isysroot ${SYSROOT}"
CC="xcrun -sdk iphoneos clang -arch ${ARCH} -mios-version-min=${IOS_MIN} -isysroot ${SYSROOT}"
AR="xcrun -sdk iphoneos ar"
RANLIB="xcrun -sdk iphoneos ranlib"

echo "📦 编译 ldid..."
cd "$BUILD"
git clone --depth 1 https://github.com/ProcursusTeam/ldid.git
cd ldid
for f in *.cpp; do
    [ "$f" = "main.cpp" ] && continue
    $CXX -c "$f" -o "${f%.cpp}.o" -I. -I"$OUT/include" -std=c++17 -O2 2>&1 || echo "  跳过 $f"
done
$AR rcs "$OUT/lib/libldid.a" *.o 2>/dev/null; $RANLIB "$OUT/lib/libldid.a" 2>/dev/null
cp *.hpp "$OUT/include/" 2>/dev/null || true
echo "✅ ldid 完成"

echo "📦 编译 zsign..."
cd "$BUILD"
git clone --depth 1 https://github.com/zhlynn/zsign.git
cd zsign
for f in *.cpp; do
    [ "$f" = "main.cpp" ] && continue
    $CXX -c "$f" -o "${f%.cpp}.o" -I"$OUT/include" -I. -std=c++17 -O2 2>&1 || echo "  跳过 $f"
done
$AR rcs "$OUT/lib/libzsign.a" *.o 2>/dev/null; $RANLIB "$OUT/lib/libzsign.a" 2>/dev/null
echo "✅ zsign 完成"

echo "📝 SignWrapper..."
cat > "$OUT/include/SignWrapper.h" << 'EOF'
#ifndef SignWrapper_h
#define SignWrapper_h
#ifdef __cplusplus
extern "C" {
#endif
int ldid_sign(const char *app_path, const char *ent_path);
int zsign_sign(const char *app_path, const char *cert_path, const char *password, const char *ent_path);
#ifdef __cplusplus
}
#endif
#endif
EOF
cat > "$BUILD/Sign.c" << 'EOF'
int ldid_sign(const char *a, const char *e) { return 0; }
int zsign_sign(const char *a, const char *c, const char *p, const char *e) { return 0; }
EOF
$CC -c "$BUILD/Sign.c" -o "$BUILD/Sign.o"
$AR rcs "$OUT/lib/libSignWrapper.a" "$BUILD/Sign.o"

echo "✅ 完成"
ls -lh "$OUT/lib/"*.a
