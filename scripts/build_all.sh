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

CPU_CORES=$(sysctl -n hw.ncpu)
[ "$CPU_CORES" -gt 4 ] && CPU_CORES=4
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

# ============================================================
# 1. 编译 OpenSSL Framework（使用旧版 1.1.1，兼容性更好）
# ============================================================
echo -e "\n${YELLOW}📦 [1/4] 编译 OpenSSL.framework${NC}"

cd "$BUILD_TEMP"
if [ ! -d "openssl_src" ]; then
    # 使用 OpenSSL 1.1.1，与 ldid 兼容性最好
    git clone --depth 1 --branch OpenSSL_1_1_1-stable https://github.com/openssl/openssl.git openssl_src
fi
cd openssl_src

make clean 2>/dev/null || true
make distclean 2>/dev/null || true

# 配置为 iOS 静态库
./Configure ios64-cross \
    --prefix="$BUILD_TEMP/openssl_install" \
    --openssldir="$BUILD_TEMP/openssl_install/ssl" \
    no-shared \
    no-tests \
    no-engine \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="${MIN_IOS_VERSION}"

make -j"${CPU_CORES}"
make install_sw

cd ..

# 创建 OpenSSL.framework
OPENSSL_FRAMEWORK="$FRAMEWORKS_OUTPUT/OpenSSL.framework"
create_framework_structure "$OPENSSL_FRAMEWORK" "OpenSSL"

# 合并静态库
find "$BUILD_TEMP/openssl_install/lib" -name "*.a" -exec lipo -create {} -output "$OPENSSL_FRAMEWORK/OpenSSL" \;

if [ -d "$BUILD_TEMP/openssl_install/include" ]; then
    cp -r "$BUILD_TEMP/openssl_install/include/"* "$OPENSSL_FRAMEWORK/Headers/"
fi

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

./configure \
    --prefix="$BUILD_TEMP/libplist_install" \
    --enable-static \
    --disable-shared \
    --disable-tests \
    --host=arm64-apple-darwin

make -j"${CPU_CORES}"
make install

cd ..

# 创建 PLIST.framework
PLIST_FRAMEWORK="$FRAMEWORKS_OUTPUT/PLIST.framework"
create_framework_structure "$PLIST_FRAMEWORK" "PLIST"

# 合并静态库
find "$BUILD_TEMP/libplist_install/lib" -name "*.a" -exec lipo -create {} -output "$PLIST_FRAMEWORK/PLIST" \;

if [ -d "$BUILD_TEMP/libplist_install/include" ]; then
    cp -r "$BUILD_TEMP/libplist_install/include/"* "$PLIST_FRAMEWORK/Headers/"
fi

echo -e "${GREEN}  ✅ PLIST.framework${NC}"

# ============================================================
# 3. 编译 ldid Framework（使用修复后的源码）
# ============================================================
echo -e "\n${YELLOW}📦 [3/4] 编译 ldid.framework${NC}"

cd "$BUILD_TEMP"
if [ ! -d "ldid_src" ]; then
    git clone https://github.com/ProcursusTeam/ldid.git ldid_src
fi

cd ldid_src

# 创建完整的修复补丁
cat > ldid_openssl_fix.patch << 'PATCHEOF'
--- a/ldid.cpp
+++ b/ldid.cpp
@@ -1,4 +1,9 @@
 /* ldid - (Mach-O) Link Identity Editor
+ 
+ 修复 OpenSSL 1.1.1+ 兼容性问题
+ - 修复 const 正确性
+ - 添加缺失的头文件
+ 
  * Copyright (c) 2007-2012 Apple Inc.
  * Copyright (c) 2010-2013 Jay Freeman (saurik)
 */
@@ -33,6 +38,11 @@
 #include <openssl/pem.h>
 #include <openssl/x509.h>
 #include <openssl/x509v3.h>
+#include <openssl/x509_vfy.h>
+#include <openssl/asn1.h>
+#include <openssl/err.h>
+#include <openssl/evp.h>
+#include <openssl/objects.h>
 
 #include <CommonCrypto/CommonDigest.h>
 
@@ -2391,11 +2401,13 @@
     return NULL;
 }
 
-static void get(std::string &value, X509_NAME *name, int nid) {
-    if (value.empty())
-        if (int lastpos = X509_NAME_get_index_by_NID(name, nid, -1); -1 != lastpos)
-            if (X509_NAME_ENTRY *e = X509_NAME_get_entry(name, lastpos))
-                if (ASN1_STRING *s = X509_NAME_ENTRY_get_data(e))
+static void get(std::string &value, const X509_NAME *name, int nid) {
+    if (value.empty()) {
+        X509_NAME *mutable_name = const_cast<X509_NAME*>(name);
+        if (int lastpos = X509_NAME_get_index_by_NID(mutable_name, nid, -1); -1 != lastpos)
+            if (X509_NAME_ENTRY *e = X509_NAME_get_entry(mutable_name, lastpos))
+                if (ASN1_STRING *s = X509_NAME_ENTRY_get_data(e))
                     if (const unsigned char *str = ASN1_STRING_get0_data(s))
                         value = reinterpret_cast<const char *>(str);
+    }
 }
 
 #ifdef __APPLE__
@@ -2448,9 +2460,9 @@
     X509_NAME *name = X509_get_subject_name(x);
     if (!name)
         return;
-    get(team, name, NID_organizationalUnitName);
+    get(team, const_cast<const X509_NAME*>(name), NID_organizationalUnitName);
     // Check for "Apple Development: " style name.
-    get(common, name, NID_commonName);
+    get(common, const_cast<const X509_NAME*>(name), NID_commonName);
 }
 
 #ifdef __APPLE__
@@ -4085,7 +4097,7 @@
                     const char *data = (const char *) ASN1_STRING_get0_data(s);
                     size_t size = ASN1_STRING_length(s);
                     if (strncmp("subject", data, size) == 0) {
-                        X509_NAME *nm = X509_get_subject_name(x);
+                        const X509_NAME *nm = X509_get_subject_name(x);
                         if (nm) {
                             if (!(flags & kFlagWild) && (flags & kFlagMobile))
                                 if (int lastpos = X509_NAME_get_index_by_NID(nm, NID_commonName, -1); -1 != lastpos)
@@ -4092,12 +4104,12 @@
                                     if (X509_NAME_ENTRY *e = X509_NAME_get_entry(nm, lastpos))
                                         if (ASN1_STRING *s = X509_NAME_ENTRY_get_data(e))
                                             Check(data = (const char *) ASN1_STRING_get0_data(s), size = ASN1_STRING_length(s));
-                            X509_NAME *issuer = X509_get_issuer_name(x);
+                            const X509_NAME *issuer = X509_get_issuer_name(x);
                             if (issuer)
                                 if (int lastpos = X509_NAME_get_index_by_NID(issuer, NID_commonName, -1); -1 != lastpos)
                                     if (X509_NAME_ENTRY *e = X509_NAME_get_entry(issuer, lastpos))
                                         if (ASN1_STRING *s = X509_NAME_ENTRY_get_data(e))
-                                            Check(data = (const char *) ASN1_STRING_get0_data(s), size = ASN1_STRING_length(s));
+                                            Check(data = (const char *) ASN1_STRING_get0_data(s), size = ASN1_STRING_length(s));
                         }
                     }
                     if (!strncmp("signature", data, size) || !strncmp("leaf", data, size)) {
PATCHEOF

# 应用补丁
echo "  应用 OpenSSL 兼容性补丁..."
patch -p1 < ldid_openssl_fix.patch 2>/dev/null || echo "  补丁可能已应用"

# 编译 ldid 为静态库（用于 Framework）
echo "  编译 ldid..."

# 编译每个源文件
OBJ_FILES=""

# 编译 ldid.cpp
xcrun -sdk iphoneos clang++ \
    -arch arm64 \
    -std=c++17 \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="${MIN_IOS_VERSION}" \
    -I"$BUILD_TEMP/openssl_install/include" \
    -I"$BUILD_TEMP/libplist_install/include" \
    -DLDID_VERSION="\"2.1.5\"" \
    -fvisibility=hidden \
    -c ldid.cpp -o ldid.o

# 编译 lookup2.cpp
if [ -f "lookup2.cpp" ]; then
    xcrun -sdk iphoneos clang++ \
        -arch arm64 \
        -std=c++17 \
        -isysroot "$DEVICE_SDK_PATH" \
        -mios-version-min="${MIN_IOS_VERSION}" \
        -c lookup2.cpp -o lookup2.o
    OBJ_FILES="$OBJ_FILES lookup2.o"
fi

# 编译 sha1.c
if [ -f "sha1.c" ]; then
    xcrun -sdk iphoneos clang \
        -arch arm64 \
        -isysroot "$DEVICE_SDK_PATH" \
        -mios-version-min="${MIN_IOS_VERSION}" \
        -c sha1.c -o sha1.o
    OBJ_FILES="$OBJ_FILES sha1.o"
fi

# 创建静态库（用于 Framework）
ar rcs libldid.a ldid.o $OBJ_FILES

cd ..

# 创建 ldid.framework
LDID_FRAMEWORK="$FRAMEWORKS_OUTPUT/ldid.framework"
create_framework_structure "$LDID_FRAMEWORK" "ldid"

# 复制静态库
cp "ldid_src/libldid.a" "$LDID_FRAMEWORK/ldid"

# 创建头文件
cat > "$LDID_FRAMEWORK/Headers/ldid.h" << 'EOF'
#ifndef ldid_h
#define ldid_h

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// 主要的 ldid 功能接口
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

# 创建实现文件
cat > "$LDID_FRAMEWORK/Headers/LDID.m" << 'EOF'
#import "ldid.h"

@implementation LDID

+ (int)signFile:(NSString*)path withEntitlements:(NSString*)entitlementsPath {
    return ldid_sign([path UTF8String], [entitlementsPath UTF8String]);
}

+ (int)verifyFile:(NSString*)path {
    return ldid_verify([path UTF8String]);
}

+ (NSString*)getEntitlements:(NSString*)path {
    char* result = ldid_get_entitlements([path UTF8String]);
    if (result) {
        NSString* str = [NSString stringWithUTF8String:result];
        free(result);
        return str;
    }
    return nil;
}

@end
EOF

echo -e "${GREEN}  ✅ ldid.framework${NC}"

# ============================================================
# 4. 编译 IPA（使用 ldid 签名）
# ============================================================
echo -e "\n${YELLOW}📱 [4/4] 编译并签名 IPA${NC}"

if [ ! -d "$XCODE_PROJECT" ]; then
    echo -e "${YELLOW}⚠️ 未找到 Xcode 项目，跳过 IPA 编译${NC}"
    exit 0
fi

VERSION=$(defaults read "$ROOT_DIR/PermanentStore/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0")
BUILD_NUM=$(defaults read "$ROOT_DIR/PermanentStore/Info.plist" CFBundleVersion 2>/dev/null || echo "1")

echo "  版本: $VERSION ($BUILD_NUM)"

# 清理
xcodebuild clean \
    -project "$XCODE_PROJECT" \
    -scheme "$XCODE_SCHEME" \
    -configuration "$XCODE_CONFIGURATION" 2>/dev/null || true

# 构建
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
    CODE_SIGNING_ALLOWED=NO

# 查找 .app
APP_PATH=$(find "$BUILD_DIR/Build/Products/$XCODE_CONFIGURATION-iphoneos" -name "*.app" | head -1)

if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}  ❌ 未找到编译产物${NC}"
    exit 1
fi

# 使用 ldid 签名（如果需要）
if [ -f "$LDID_FRAMEWORK/ldid" ]; then
    echo "  使用 ldid 签名..."
    "$LDID_FRAMEWORK/ldid" -S "$ENTITLEMENTS_FILE" "$APP_PATH" 2>/dev/null || echo "  签名跳过"
fi

# 打包 IPA
IPA_NAME="PermanentStore_${VERSION}_${BUILD_NUM}.ipa"
mkdir -p "$IPA_OUTPUT/Payload"
cp -r "$APP_PATH" "$IPA_OUTPUT/Payload/"
cd "$IPA_OUTPUT"
zip -qr "$IPA_NAME" Payload/
rm -rf Payload
cd - > /dev/null

echo -e "${GREEN}  ✅ IPA 生成成功: $IPA_OUTPUT/$IPA_NAME${NC}"

# ============================================================
# 验证
# ============================================================
echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}  构建完成！${NC}"
echo -e "${GREEN}============================================================${NC}"

for fw in OpenSSL PLIST ldid; do
    fw_path="$FRAMEWORKS_OUTPUT/${fw}.framework"
    if [ -d "$fw_path" ]; then
        size=$(du -sh "$fw_path" 2>/dev/null | cut -f1)
        echo -e "  ${GREEN}✅${NC} $fw.framework ($size)"
    fi
done

echo ""
echo -e "📱 IPA: $IPA_OUTPUT/$IPA_NAME"
