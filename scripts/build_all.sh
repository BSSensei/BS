#!/bin/bash
set -euo pipefail

# ===================== 颜色定义 =====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ===================== 路径配置 =====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_FILE="$ROOT_DIR/build_log.txt"

# ===================== 日志系统 =====================
exec > >(tee -i "$LOG_FILE")
exec 2>&1

trap 'echo -e "${RED}❌ 构建失败，详见日志：$LOG_FILE${NC}"; gzip "$LOG_FILE" 2>/dev/null || true' ERR

# ===================== 基础配置 =====================
BUILD_TEMP="$ROOT_DIR/BuildTemp"
LIBS_OUTPUT="$ROOT_DIR/Frameworks"
RESOURCES_OUTPUT="$ROOT_DIR/Resources"
IPA_OUTPUT="$ROOT_DIR/IPA"
LDID_SOURCE_DIR="$ROOT_DIR/ldid"

mkdir -p "$BUILD_TEMP" "$LIBS_OUTPUT" "$RESOURCES_OUTPUT" "$IPA_OUTPUT"

DEVICE_SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
if [ -z "$DEVICE_SDK_PATH" ]; then
  echo -e "${RED}❌ 未找到 iOS SDK 路径${NC}"
  exit 1
fi

MIN_IOS_VERSION="12.0"
APP_NAME="PermanentStore"
VERSION="1.0"
CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
[ "$CPU_CORES" -gt 4 ] && CPU_CORES=4

# ===================== 搜索关键文件 =====================
search_file() {
    local filename="$1"
    find "$ROOT_DIR" -type f -name "$filename" \
        ! -path "*/BuildTemp/*" \
        ! -path "*/.git/*" \
        ! -path "*/IPA/*" \
        ! -path "*/Frameworks/*" | head -1
}

ENTITLEMENTS_FILE=$(search_file "entitlements.plist")
INFO_PLIST_FILE=$(search_file "Info.plist")
ICON_FILE=$(search_file "Icon.png")

if [ -z "$ENTITLEMENTS_FILE" ] || [ -z "$INFO_PLIST_FILE" ]; then
    echo -e "${RED}❌ 未找到必要的配置文件${NC}"; exit 1
fi

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}  PermanentStore 完整构建${NC}"
echo -e "${BLUE}============================================================${NC}"

# ===================== 1. OpenSSL =====================
echo -e "\n${YELLOW}📦 [1/5] OpenSSL${NC}"
cd "$BUILD_TEMP" || exit 1
if [ ! -d openssl_install ]; then
    [ -d openssl ] || git clone --depth 1 https://github.com/openssl/openssl.git openssl
    cd openssl || exit 1
    ./Configure ios64-cross \
        --prefix="$BUILD_TEMP/openssl_install" \
        no-shared no-tests \
        -isysroot "$DEVICE_SDK_PATH" \
        -mios-version-min="$MIN_IOS_VERSION"
    make -j"$CPU_CORES"
    make install_sw
    cd ..
fi
echo -e "${GREEN}✅ OpenSSL 完成${NC}"

# ===================== 2. libplist =====================
echo -e "\n${YELLOW}📦 [2/5] libplist${NC}"
cd "$BUILD_TEMP" || exit 1
if [ ! -d libplist_install ]; then
    [ -d libplist ] || git clone --depth 1 https://github.com/libimobiledevice/libplist.git libplist
    cd libplist || exit 1
    [ ! -f configure ] && ./autogen.sh
    ./configure \
        --prefix="$BUILD_TEMP/libplist_install" \
        --host=aarch64-apple-darwin \
        --enable-static --disable-shared --disable-tests \
        CC="xcrun -sdk iphoneos clang" \
        CXX="xcrun -sdk iphoneos clang++" \
        CFLAGS="-arch arm64 -isysroot $DEVICE_SDK_PATH -mios-version-min=$MIN_IOS_VERSION" \
        CXXFLAGS="-arch arm64 -isysroot $DEVICE_SDK_PATH -mios-version-min=$MIN_IOS_VERSION"
    make -j"$CPU_CORES"
    make install
    cd ..
fi
echo -e "${GREEN}✅ libplist 完成${NC}"

# ===================== 3. ldid（使用补丁修复）=====================
echo -e "\n${YELLOW}📦 [3/5] ldid${NC}"

if [ ! -d "$LDID_SOURCE_DIR" ] || [ ! -f "$LDID_SOURCE_DIR/ldid.cpp" ]; then
    echo -e "${RED}❌ 未找到 ldid 源码${NC}"; exit 1
fi

cd "$BUILD_TEMP" || exit 1
rm -rf ldid_build
mkdir -p ldid_build
cp -r "$LDID_SOURCE_DIR/." ldid_build/
cd ldid_build || exit 1

# 应用补丁
cat > ldid_fix.patch << 'PATCH_END'
--- a/ldid.cpp
+++ b/ldid.cpp
@@ -1,3 +1,11 @@
+#define OPENSSL_API_COMPAT 0x10100000L
+#define OPENSSL_NO_DEPRECATED 0
+#include <memory>
+#include <vector>
+#include <cstring>
+#include <openssl/conf.h>
+#include <openssl/asn1.h>
+#include <openssl/x509v3.h>
+
 /*
  * Copyright (c) 2007-2013, 2017, 2019, 2020, 2021, 2022, 2023
  *   Jay Freeman (saurik)
@@ -548,10 +556,12 @@ static inline void get(std::streambuf &stream, void *data, size_t size) {
 }
 
 static inline void pad(std::streambuf &stream, size_t size) {
-    char padding[size];
-    memset(padding, 0, size);
-    put(stream, padding, size);
+    std::vector<char> padding(size, 0);
+    put(stream, padding.data(), size);
 }
+static void get(std::string &value, const X509_NAME *name, int nid) {
+    get(value, const_cast<X509_NAME*>(name), nid);
+}
 
 template <typename Type_>
 static inline void get(std::streambuf &stream, Type_ &value) {
@@ -2394,6 +2404,10 @@ static void get(std::string &value, X509_NAME *name, int nid) {
     if (n < 0)
         return;
     X509_NAME_ENTRY *e = X509_NAME_get_entry(name, n);
+    if (!e) return;
+    ASN1_STRING *asn = X509_NAME_ENTRY_get_data(e);
+    const unsigned char *data = ASN1_STRING_get0_data(asn);
+    value.assign(reinterpret_cast<const char *>(data), ASN1_STRING_length(asn));
 }
 
 static void req(std::streambuf &buffer, uint32_t value) {
@@ -2448,9 +2462,9 @@ static identity *load(X509 *cert, EVP_PKEY *key, const std::string &file) {
     if (name) {
         std::string org, common, team;
         if (organization)
-            get(org, name, NID_organizationName);
+            get(org, const_cast<X509_NAME*>(name), NID_organizationName);
         if (commonName)
-            get(common, name, NID_commonName);
+            get(common, const_cast<X509_NAME*>(name), NID_commonName);
         if (teamIdentifier)
             get(team, name, NID_organizationalUnitName);
         
@@ -3076,10 +3090,13 @@ static void sign_constraints(FILE *file, std::streambuf &stream, const std::vec<
         std::vector<std::pair<size_t, size_t>> matches_;
         for (auto flag : flags)
             if (regexec(&flag.second.first, begin, matches_.size(), nullptr, 0) == 0)
-                matches_.push_back(flag.first);
+                matches_.push_back(std::make_pair(flag.first.first, flag.first.second));
+        std::vector<regmatch_t> matches(matches_.size());
         if (matches_.empty())
             continue;
         
+        for (size_t i = 0; i < matches_.size(); i++)
+            matches[i] = {matches_[i].first, matches_[i].second};
         std::string out;
         if (flags[0].second.second(out, begin, end, &matches[0]))
             continue;
@@ -3489,7 +3506,7 @@ int main(int argc, char *argv[])
         setlocale(LC_ALL, "");
     }
     
-    fprintf(stderr, "Link Identity Editor %s\n\n", LDID_VERSION);
+    fprintf(stderr, "Link Identity Editor %s\n\n", "2.1.5");
     
     flag64 = false;
     flagent = false;
@@ -4002,7 +4019,7 @@ int main(int argc, char *argv[])
                         auto *cdhash = reinterpret_cast<cdhash_struct *>(slot.data());
                         
                         auto &algorithm(*algorithms[type - 1]);
-                        uint8_t hash[algorithm.size_];
+                        std::vector<uint8_t> hash(algorithm.size_);
                         
                         switch (type) {
                             case 1:
@@ -4016,7 +4033,7 @@ int main(int argc, char *argv[])
                                 SHA256(reinterpret_cast<const unsigned char *>(code.data()), code.size(), hash.data());
                                 break;
                         }
-                        _assert(memcmp(cdhash->hash, hash, algorithm.size_) == 0);
+                        _assert(memcmp(cdhash->hash, hash.data(), algorithm.size_) == 0);
                         break;
                     }
                     default:
@@ -4085,7 +4102,7 @@ int main(int argc, char *argv[])
                         const unsigned char *data = reinterpret_cast<const unsigned char *>(code.data());
                         X509 *x = d2i_X509(NULL, &data, code.size());
                         if (x) {
-                            X509_NAME *nm = X509_get_subject_name(x);
+                            const X509_NAME *nm = X509_get_subject_name(x);
                             // find the team identifier
                             for (int lastpos = -1;;) {
                                 int pos = X509_NAME_get_index_by_NID(nm, NID_organizationalUnitName, lastpos);
@@ -4093,13 +4110,15 @@ int main(int argc, char *argv[])
                                     break;
                                 lastpos = pos;
                                 X509_NAME_ENTRY *e = X509_NAME_get_entry(nm, lastpos);
-                                ASN1_STRING *s = X509_NAME_ENTRY_get_data(e);
-                                char *team = reinterpret_cast<char *>(ASN1_STRING_data(s));
-                                _assert(ASN1_STRING_length(s) <= sizeof(identity->team) - 1);
-                                memcpy(identity->team, team, ASN1_STRING_length(s));
-                                identity->team[ASN1_STRING_length(s)] = 0;
+                                if (e) {
+                                    ASN1_STRING *s = X509_NAME_ENTRY_get_data(e);
+                                    const unsigned char *team_ptr = ASN1_STRING_get0_data(s);
+                                    int len = ASN1_STRING_length(s);
+                                    _assert(len <= static_cast<int>(sizeof(identity->team) - 1));
+                                    memcpy(identity->team, team_ptr, len);
+                                    identity->team[len] = 0;
+                                }
                             }
                             identity->cert = x;
                         }
PATCH_END

# 应用补丁
patch -p0 < ldid_fix.patch 2>/dev/null || true

# 编译
echo -e "${BLUE}🛠️ 编译 ldid...${NC}"
xcrun -sdk iphoneos clang++ -std=c++14 \
    -arch arm64 \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="$MIN_IOS_VERSION" \
    -I"$BUILD_TEMP/openssl_install/include" \
    -DHAVE_OPENSSL=1 \
    -o "$RESOURCES_OUTPUT/ldid" \
    ldid.cpp \
    "$BUILD_TEMP/openssl_install/lib/libcrypto.a" \
    -framework Foundation -framework Security

if [ -f "$RESOURCES_OUTPUT/ldid" ]; then
    echo -e "${GREEN}✅ ldid 编译成功${NC}"
else
    echo -e "${RED}❌ ldid 编译失败${NC}"
    exit 1
fi

# ===================== 4. zsign =====================
echo -e "\n${YELLOW}📦 [4/5] zsign${NC}"
cd "$BUILD_TEMP" || exit 1
if [ ! -d zsign ]; then
    git clone --depth 1 https://github.com/zhlynn/zsign.git zsign
fi
cd zsign || exit 1

xcrun -sdk iphoneos clang++ -std=c++11 \
    -arch arm64 \
    -isysroot "$DEVICE_SDK_PATH" \
    -mios-version-min="$MIN_IOS_VERSION" \
    -I"$BUILD_TEMP/openssl_install/include" \
    -I"$BUILD_TEMP/libplist_install/include" \
    -L"$BUILD_TEMP/openssl_install/lib" \
    -L"$BUILD_TEMP/libplist_install/lib" \
    -o "$RESOURCES_OUTPUT/zsign" \
    *.cpp \
    -lcrypto -lssl -lplist-2.0

echo -e "${GREEN}✅ zsign 完成${NC}"

# ===================== 5. Swift App =====================
echo -e "\n${YELLOW}📦 [5/5] Swift App${NC}"

SWIFT_FILES=$(find "$ROOT_DIR" -name "*.swift" ! -path "*/BuildTemp/*" 2>/dev/null)
if [ -z "$SWIFT_FILES" ]; then
    echo -e "${RED}❌ 未找到 Swift 文件${NC}"
    exit 1
fi

APP_DIR="$BUILD_TEMP/Payload/$APP_NAME.app"
mkdir -p "$APP_DIR"

echo -e "${BLUE}🔨 编译 Swift...${NC}"
xcrun -sdk iphoneos swiftc \
    -target arm64-apple-ios$MIN_IOS_VERSION \
    -sdk "$DEVICE_SDK_PATH" \
    -O \
    -framework Foundation UIKit UniformTypeIdentifiers \
    -o "$APP_DIR/$APP_NAME" \
    $SWIFT_FILES

# 复制资源和工具
cp "$INFO_PLIST_FILE" "$APP_DIR/Info.plist"
cp "$ENTITLEMENTS_FILE" "$APP_DIR/entitlements.plist"
[ -n "$ICON_FILE" ] && cp "$ICON_FILE" "$APP_DIR/Icon.png"
cp "$RESOURCES_OUTPUT/ldid" "$APP_DIR/"
cp "$RESOURCES_OUTPUT/zsign" "$APP_DIR/"
chmod +x "$APP_DIR"/* 2>/dev/null || true

# ===================== 打包 IPA =====================
cd "$BUILD_TEMP" || exit 1
IPA_PATH="$IPA_OUTPUT/${APP_NAME}_${VERSION}.ipa"
zip -qr "$IPA_PATH" Payload

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}  构建完成 ✅${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "${BLUE}📦 IPA 路径：$IPA_PATH${NC}"
echo -e "${BLUE}📄 构建日志：$LOG_FILE${NC}"

gzip -f "$LOG_FILE" 2>/dev/null || true
