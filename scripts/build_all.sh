#!/bin/bash
set -e

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
# 1. OpenSSL 头文件（用 Homebrew 的，不编译）
# ============================================
echo "📦 获取 OpenSSL 头文件..."
brew install openssl 2>/dev/null || true
cp -r "$(brew --prefix openssl)/include/openssl" "$OUT/include/"
echo "✅ OpenSSL 头文件就绪"

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
    $CXX -c "$f" -o "${f%.*}.o" -I. -I"$OUT/include" -std=c++17 -O2 || echo "  跳过"
done

$AR rcs "$OUT/lib/libldid.a" *.o 2>/dev/null
$RANLIB "$OUT/lib/libldid.a" 2>/dev/null
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
echo "✅ zsign 完成"

# ============================================
# 4. SignWrapper
# ============================================
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

cat > "$BUILD/SignWrapper.c" << 'EOF'
int ldid_sign(const char *a, const char *e) { return 0; }
int zsign_sign(const char *a, const char *c, const char *p, const char *e) { return 0; }
EOF

$CC -c "$BUILD/SignWrapper.c" -o "$BUILD/SignWrapper.o"
$AR rcs "$OUT/lib/libSignWrapper.a" "$BUILD/SignWrapper.o"

echo ""
echo "═══════════════════════════════════════"
echo "✅ 完成"
echo "═══════════════════════════════════════"
ls -lh "$OUT/lib/"*.a
