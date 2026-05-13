#!/bin/bash
set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# 路径设置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_TEMP="$ROOT_DIR/build_temp"
mkdir -p "$BUILD_TEMP"

# SDK 路径
SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
if [ -z "$SDK_PATH" ]; then
    echo -e "${RED}❌ 无法找到 iPhoneOS SDK${NC}"
    exit 1
fi
echo "✅ SDK: $SDK_PATH"

# 清理旧目录
echo "🔧 清理旧构建目录..."
rm -rf "$BUILD_TEMP/openssl" "$BUILD_TEMP/openssl_install"
rm -rf "$BUILD_TEMP/libplist" "$BUILD_TEMP/libplist_install"
rm -rf "$BUILD_TEMP/ldid" "$BUILD_TEMP/ldid_install"

# ============================================================
# 1. 编译 OpenSSL（保持不变，但输出路径明确）
# ============================================================
echo -e "\n============================================================"
echo "📦 [1/4] 编译 OpenSSL"
echo "============================================================"
cd "$BUILD_TEMP"
git clone --depth 1 https://github.com/openssl/openssl.git
cd openssl
./Configure ios64-cross --prefix="$BUILD_TEMP/openssl_install" --openssldir="$BUILD_TEMP/openssl_install/ssl" no-shared no-tests
make -j$(sysctl -n hw.ncpu)
make install_sw
cd ..
echo -e "${GREEN}✅ OpenSSL 编译完成${NC}"

# ============================================================
# 2. 编译 libplist（修复 config.h 缺失）
# ============================================================
echo -e "\n============================================================"
echo "📦 [2/4] 编译 libplist"
echo "============================================================"
cd "$BUILD_TEMP"
git clone --depth 1 https://github.com/libimobiledevice/libplist.git
cd libplist
# 修复：生成 config.h
./autogen.sh --prefix="$BUILD_TEMP/libplist_install" --disable-shared --enable-static
make -j$(sysctl -n hw.ncpu)
make install
cd ..
echo -e "${GREEN}✅ libplist 编译完成${NC}"

# ============================================================
# 3. 编译 ldid（修复 OpenSSL 路径和代码问题）
# ============================================================
echo -e "\n============================================================"
echo "📦 [3/4] 编译 ldid"
echo "============================================================"
cd "$BUILD_TEMP"
git clone --depth 1 https://github.com/ProcursusTeam/ldid.git
cd ldid

# 应用补丁
cat > ldid_fixes.patch << 'EOF'
--- a/ldid.cpp
+++ b/ldid.cpp
@@ -35,6 +35,10 @@
 #include <CommonCrypto/CommonDigest.h>
 #endif

+// 定义版本号
+#ifndef LDID_VERSION
+#define LDID_VERSION "2.1.5-procursus"
+#endif

 // 避免与标准库的 get 冲突
 static void x509_get(std::string &value, X509_NAME *name, int nid) {
@@ -2448,9 +2452,9 @@
     }

     // Get Team ID and Common Name
-    get(team, name, NID_organizationalUnitName);
+    x509_get(team, name, NID_organizationalUnitName);
     if (team.empty())
-        get(team, name, NID_organizationName);
+        x509_get(team, name, NID_organizationName);

     // Extract the Common Name (CN)
     std::string common;
@@ -2458,9 +2462,9 @@
     //   the NID_commonName may appear multiple times, pick the last one? For
     //   now we prefer the CN that's also a "iPhone Developer: ..." pattern
     //   as seen in the wild? maybe not? just pick the last one.
-    get(common, name, NID_commonName);
+    x509_get(common, name, NID_commonName);
     if (common.empty())
-        get(common, name, NID_pkcs9_emailAddress);
+        x509_get(common, name, NID_pkcs9_emailAddress);

     // Sometimes CN is stored in UID (Mac Developer)
     if (common.empty())
@@ -4085,7 +4089,7 @@
                                 size_t pos = 0;
                                 int lastpos = -1;
                                 X509_NAME_ENTRY *e = NULL;
-                                X509_NAME *nm = X509_get_subject_name(x);
+                                X509_NAME *nm = const_cast<X509_NAME*>(X509_get_subject_name(x));
                                 while ((e = X509_NAME_get_entry(nm, ++lastpos))) {
                                     ASN1_STRING *s = X509_NAME_ENTRY_get_data(e);
                                     std::string value((char *)ASN1_STRING_get0_data(s), ASN1_STRING_length(s));
@@ -4094,7 +4098,7 @@
                                 lastpos = -1;
                                 while ((e = X509_NAME_get_entry(nm, ++lastpos))) {
                                     ASN1_STRING *s = X509_NAME_ENTRY_get_data(e);
-                                    if (ASN1_STRING_type(s) != V_ASN1_PRINTABLESTRING && ASN1_STRING_type(s) != V_ASN1_T61STRING)
+                                    if (ASN1_STRING_type(s) != V_ASN1_PRINTABLESTRING && ASN1_STRING_type(s) != V_ASN1_T61STRING && ASN1_STRING_type(s) != V_ASN1_UTF8STRING)
                                         continue;
                                     std::string value((char *)ASN1_STRING_get0_data(s), ASN1_STRING_length(s));
                                     if (pos == 0)
EOF

git apply ldid_fixes.patch

# 设置 OpenSSL 路径
export CFLAGS="-I$BUILD_TEMP/openssl_install/include"
export LDFL
