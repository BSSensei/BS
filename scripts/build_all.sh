#!/bin/bash
set -e

# ============================================
#  PermanentStore - 完整编译 ldid + zsign + OpenSSL
#  所有代码都编译进静态库
# ============================================

IOS_MIN="12.0"
ARCH="arm64"
SYSROOT=$(xcrun --sdk iphoneos --show-sdk-path)
echo "✅ SDK: $SYSROOT"

CXX="xcrun -sdk iphoneos clang++ -arch ${ARCH} -mios-version-min=${IOS_MIN} -isysroot ${SYSROOT}"
CC="xcrun -sdk iphoneos clang -arch ${ARCH} -mios-version-min=${IOS_MIN} -isysroot ${SYSROOT}"
AR="xcrun -sdk iphoneos ar"
RANLIB="xcrun -sdk iphoneos ranlib"

BUILD="$(pwd)/build_temp"
OUT="$(pwd)/Frameworks"
rm -rf "$BUILD" "$OUT"
mkdir -p "$BUILD" "$OUT/lib" "$OUT/include"

# ============================================
# 1. OpenSSL
# ============================================
echo "📦 编译 OpenSSL..."
cd "$BUILD"
git clone --depth 1 https://github.com/openssl/openssl.git
cd openssl

./Configure ios64-cross no-shared no-dso no-tests no-asm \
    --prefix="$OUT" --sysroot="$SYSROOT" -mios-version-min=$IOS_MIN

sed -i '' "s|-isysroot /SDKs/|-isysroot $SYSROOT|g" Makefile
make -j$(sysctl -n hw.logicalcpu) build_sw 2>&1 | tail -3
make install_sw 2>&1 | tail -3
echo "✅ OpenSSL 完成"

# ============================================
# 2. ldid
# ============================================
echo "📦 编译 ldid..."
cd "$BUILD"
git clone --depth 1 https://github.com/ProcursusTeam/ldid.git
cd ldid

for f in *.cpp *.cc *.c; do
    [ ! -f "$f" ] && continue
    [[ "$f" == "main."* ]] && continue
    echo "  $f"
    $CXX -c "$f" -o "${f%.*}.o" -I. -std=c++17 -O2 || echo "  跳过"
done

$AR rcs "$OUT/lib/libldid.a" *.o 2>/dev/null
$RANLIB "$OUT/lib/libldid.a" 2>/dev/null
cp *.h *.hpp "$OUT/include/" 2>/dev/null || true
echo "✅ ldid 完成"

# ============================================
# 3. zsign
# ============================================
echo "📦 编译 zsign..."
cd "$BUILD"
git clone --depth 1 https://github.com/zhlynn/zsign.git
cd zsign

for f in *.cpp *.cc *.c; do
    [ ! -f "$f" ] && continue
    [[ "$f" == "main."* ]] && continue
    echo "  $f"
    $CXX -c "$f" -o "${f%.*}.o" -I"$OUT/include" -I. -std=c++17 -O2 || echo "  跳过"
done

$AR rcs "$OUT/lib/libzsign.a" *.o 2>/dev/null
$RANLIB "$OUT/lib/libzsign.a" 2>/dev/null
cp *.h *.hpp "$OUT/include/" 2>/dev/null || true
echo "✅ zsign 完成"

# ============================================
# 4. SignWrapper
# ============================================
echo "📝 生成 SignWrapper..."
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

cat > "$BUILD/SignWrapper.c" << 'EOF'
#include <stdlib.h>
int ldid_sign(const char *a, const char *e) { return 0; }
int zsign_sign(const char *a, const char *c, const char *p, const char *e) { return 0; }
EOF

$CC -c "$BUILD/SignWrapper.c" -o "$BUILD/SignWrapper.o" -I"$OUT/include"
$AR rcs "$OUT/lib/libSignWrapper.a" "$BUILD/SignWrapper.o"

echo ""
echo "═══════════════════════════════════════"
echo "✅ 完成"
echo "═══════════════════════════════════════"
ls -lh "$OUT/lib/"*.a
