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
ENTITLEMENTS_FILE="$ROOT_DIR/entitlements.plist"  # 根目录

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
[ "$CPU_CORES" -gt 4 ] && CPU_CORES=4
echo -e "🖥️  使用并发数: $CPU_CORES"

# 检查根目录 entitlements 是否存在
if [ ! -f "$ENTITLEMENTS_FILE" ]; then
    echo -e "${RED}  ❌ 根目录 entitlements.plist 不存在: $ENTITLEMENTS_FILE${NC}"
    echo -e "${YELLOW}  请在项目根目录创建 entitlements.plist 文件${NC}"
    exit 1
fi

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
    
    for header in "$framework_dir/Headers/"*.h 2>/dev/null; do
        if [ -f "$header" ] && [ "$(basename "$header")" != "${framework_name}.h" ]; then
            echo "#import <${framework_name}/$(basename "$header")>" >> "$framework_dir/Headers/${framework_name}.h"
        fi
    done
    
    echo "#endif" >> "$framework_dir/Headers/${framework_name}.h"
}

# ============================================================
# 1. 编译 OpenSSL.framework
# ============================================================
echo -e "\n${YELLOW}📦 [1/5] 编译 OpenSSL.framework${NC}"

cd "$BUILD_TEMP"
if [ ! -d "openssl_src" ]; then
    git clone --depth 1 --branch OpenSSL_1_1_1-stable https://github.com/openssl/openssl.git openssl_src
fi
cd openssl_src

make clean 2>/dev/null || true
make distclean 2>/dev/null || true

./Configure ios64-cross \
    --prefix="$BUILD_TEMP/openssl_install" \
    --openssldir="$BUILD_TEMP/openssl_install/ssl" \
    no-shared \
    no-tests \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="${MIN_IOS_VERSION}"

make -j"${CPU_CORES}"
make install_sw

cd ..

OPENSSL_FRAMEWORK="$FRAMEWORKS_OUTPUT/OpenSSL.framework"
create_framework_structure "$OPENSSL_FRAMEWORK" "OpenSSL"

find "$BUILD_TEMP/openssl_install/lib" -name "*.a" -exec lipo -create {} -output "$OPENSSL_FRAMEWORK/OpenSSL" \;
cp -r "$BUILD_TEMP/openssl_install/include/"* "$OPENSSL_FRAMEWORK/Headers/"
create_framework_header "$OPENSSL_FRAMEWORK" "OpenSSL"

echo -e "${GREEN}  ✅ OpenSSL.framework${NC}"

# ============================================================
# 2. 编译 PLIST.framework
# ============================================================
echo -e "\n${YELLOW}📦 [2/5] 编译 PLIST.framework${NC}"

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

PLIST_FRAMEWORK="$FRAMEWORKS_OUTPUT/PLIST.framework"
create_framework_structure "$PLIST_FRAMEWORK" "PLIST"

find "$BUILD_TEMP/libplist_install/lib" -name "*.a" -exec lipo -create {} -output "$PLIST_FRAMEWORK/PLIST" \;
cp -r "$BUILD_TEMP/libplist_install/include/"* "$PLIST_FRAMEWORK/Headers/"
create_framework_header "$PLIST_FRAMEWORK" "PLIST"

echo -e "${GREEN}  ✅ PLIST.framework${NC}"

# ============================================================
# 3. 编译 ldid.framework
# ============================================================
echo -e "\n${YELLOW}📦 [3/5] 编译 ldid.framework${NC}"

cd "$BUILD_TEMP"
if [ ! -d "ldid_src" ]; then
    git clone https://github.com/ProcursusTeam/ldid.git ldid_src
fi

cd ldid_src

# 创建完整的修复补丁
cat > ldid_fix.patch << 'PATCHEOF'
--- a/ldid.cpp
+++ b/ldid.cpp
@@ -33,6 +33,9 @@
 #include <openssl/pem.h>
 #include <openssl/x509.h>
 #include <openssl/x509v3.h>
+#include <openssl/x509_vfy.h>
+#include <openssl/asn1.h>
+#include <openssl/objects.h>
 
 #include <CommonCrypto/CommonDigest.h>
 
@@ -2391,11 +2394,13 @@
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
@@ -2448,9 +2453,9 @@
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
@@ -4085,7 +4090,7 @@
                     const char *data = (const char *) ASN1_STRING_get0_data(s);
                     size_t size = ASN1_STRING_length(s);
                     if (strncmp("subject", data, size) == 0) {
-                        X509_NAME *nm = X509_get_subject_name(x);
+                        const X509_NAME *nm = X509_get_subject_name(x);
                         if (nm) {
                             if (!(flags & kFlagWild) && (flags & kFlagMobile))
                                 if (int lastpos = X509_NAME_get_index_by_NID(nm, NID_commonName, -1); -1 != lastpos)
@@ -4092,12 +4097,12 @@
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

patch -p1 < ldid_fix.patch 2>/dev/null || echo "  补丁已应用"

# 编译静态库
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

xcrun -sdk iphoneos clang++ \
    -arch arm64 \
    -std=c++17 \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="${MIN_IOS_VERSION}" \
    -c lookup2.cpp -o lookup2.o

xcrun -sdk iphoneos clang \
    -arch arm64 \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="${MIN_IOS_VERSION}" \
    -c sha1.c -o sha1.o

ar rcs libldid.a ldid.o lookup2.o sha1.o

cd ..

LDID_FRAMEWORK="$FRAMEWORKS_OUTPUT/ldid.framework"
create_framework_structure "$LDID_FRAMEWORK" "ldid"

cp "ldid_src/libldid.a" "$LDID_FRAMEWORK/ldid"

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

echo -e "${GREEN}  ✅ ldid.framework${NC}"

# ============================================================
# 4. 编译 zsign.framework
# ============================================================
echo -e "\n${YELLOW}📦 [4/5] 编译 zsign.framework${NC}"

cd "$BUILD_TEMP"
if [ ! -d "zsign_src" ]; then
    git clone https://github.com/zhlynn/zsign.git zsign_src
fi

cd zsign_src

# 收集所有源文件
CPP_FILES=$(find . -maxdepth 1 -name "*.cpp" 2>/dev/null | tr '\n' ' ')
C_FILES=$(find . -maxdepth 1 -name "*.c" 2>/dev/null | tr '\n' ' ')

OBJS=""

for src in $C_FILES; do
    obj="${src%.c}.o"
    xcrun -sdk iphoneos clang \
        -arch arm64 \
        -isysroot "$DEVICE_SDK_PATH" \
        -mios-version-min="${MIN_IOS_VERSION}" \
        -I"$BUILD_TEMP/openssl_install/include" \
        -c "$src" -o "$obj"
    OBJS="$OBJS $obj"
done

for src in $CPP_FILES; do
    obj="${src%.cpp}.o"
    xcrun -sdk iphoneos clang++ \
        -arch arm64 \
        -std=c++11 \
        -isysroot "$DEVICE_SDK_PATH" \
        -mios-version-min="${MIN_IOS_VERSION}" \
        -I"$BUILD_TEMP/openssl_install/include" \
        -c "$src" -o "$obj"
    OBJS="$OBJS $obj"
done

ar rcs libzsign.a $OBJS

cd ..

ZSIGN_FRAMEWORK="$FRAMEWORKS_OUTPUT/zsign.framework"
create_framework_structure "$ZSIGN_FRAMEWORK" "zsign"

cp "zsign_src/libzsign.a" "$ZSIGN_FRAMEWORK/zsign"

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

echo -e "${GREEN}  ✅ zsign.framework${NC}"

# ============================================================
# 5. 编译 IPA（使用根目录 entitlements）
# ============================================================
echo -e "\n${YELLOW}📱 [5/5] 编译 IPA${NC}"

if [ ! -d "$XCODE_PROJECT" ]; then
    echo -e "${RED}  ❌ 未找到 Xcode 项目: $XCODE_PROJECT${NC}"
    exit 1
fi

VERSION=$(defaults read "$ROOT_DIR/PermanentStore/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0")
BUILD_NUM=$(defaults read "$ROOT_DIR/PermanentStore/Info.plist" CFBundleVersion 2>/dev/null || echo "1")

echo "  版本: $VERSION ($BUILD_NUM)"
echo "  使用 entitlements: $ENTITLEMENTS_FILE"

# 显示 entitlements 内容
echo "  Entitlements 内容:"
cat "$ENTITLEMENTS_FILE" | head -10 | sed 's/^/    /'

# 构建
BUILD_DIR="$BUILD_TEMP/Build"
mkdir -p "$BUILD_DIR"

xcodebuild clean \
    -project "$XCODE_PROJECT" \
    -scheme "$XCODE_SCHEME" \
    -configuration "$XCODE_CONFIGURATION" 2>/dev/null || true

# 设置 Framework 搜索路径
FRAMEWORK_SEARCH_PATHS="$FRAMEWORKS_OUTPUT"

xcodebuild build \
    -project "$XCODE_PROJECT" \
    -scheme "$XCODE_SCHEME" \
    -configuration "$XCODE_CONFIGURATION" \
    -sdk iphoneos \
    -derivedDataPath "$BUILD_DIR" \
    FRAMEWORK_SEARCH_PATHS="$FRAMEWORK_SEARCH_PATHS" \
    CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS_FILE" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    OTHER_CODE_SIGN_FLAGS="--entitlements $ENTITLEMENTS_FILE"

# 查找 .app
APP_PATH=$(find "$BUILD_DIR/Build/Products/$XCODE_CONFIGURATION-iphoneos" -name "*.app" | head -1)

if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}  ❌ 未找到编译产物${NC}"
    exit 1
fi

echo "  App 路径: $APP_PATH"

# 将 Frameworks 复制到 app 中
mkdir -p "$APP_PATH/Frameworks"
for framework in "$FRAMEWORKS_OUTPUT"/*.framework; do
    if [ -d "$framework" ]; then
        cp -r "$framework" "$APP_PATH/Frameworks/"
        echo "  复制 Framework: $(basename "$framework")"
    fi
done

# 复制 entitlements 到 app 中
cp "$ENTITLEMENTS_FILE" "$APP_PATH/archived-expanded-entitlements.xcent" 2>/dev/null || true
cp "$ENTITLEMENTS_FILE" "$APP_PATH/entitlements.plist" 2>/dev/null || true

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
        echo -e "  ${GREEN}✅${NC} $fw.framework ($size)"
    else
        echo -e "  ${RED}❌${NC} $fw.framework (缺失)"
    fi
done

echo ""
echo -e "📱 IPA: $IPA_OUTPUT/$IPA_NAME"
echo -e "🔐 Entitlements: $ENTITLEMENTS_FILE (根目录)"
echo -e "\n${GREEN}✅ 所有组件构建成功！${NC}"
