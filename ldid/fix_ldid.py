#!/usr/bin/env python3
"""精准修复 ldid.cpp 在 iOS arm64 + OpenSSL 3.0 下的兼容性问题"""

import re
import sys

def fix_ldid(filepath):
    with open(filepath, 'r') as f:
        content = f.read()
    
    original = content
    
    # ===== 1. 文件开头添加 OpenSSL 头文件 =====
    headers = '''#define OPENSSL_API_COMPAT 0x10100000L
#define OPENSSL_NO_DEPRECATED 0
#include <memory>
#include <vector>
#include <cstring>
#include <openssl/conf.h>
#include <openssl/asn1.h>
#include <openssl/asn1t.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
'''
    # 在第一个 #include 之前插入
    content = re.sub(r'(#include)', headers + r'\1', content, count=1)
    
    # ===== 2. 定义 LDID_VERSION =====
    ld_version = '\n#ifndef LDID_VERSION\n#define LDID_VERSION "2.1.5"\n#endif\n'
    # 在 #include "minimal.c" 之后插入
    content = content.replace('#include "minimal.c"', '#include "minimal.c"' + ld_version)
    
    # ===== 3. 修复 pad 函数的 VLA =====
    content = re.sub(
        r'static inline void pad\(std::streambuf &stream, size_t size\) \{\s*char padding\[size\];\s*memset\(padding, 0, size\);\s*put\(stream, padding, size\);\s*\}',
        '''static inline void pad(std::streambuf &stream, size_t size) {
    // FIXED: replaced VLA with vector
    std::vector<char> padding(size, 0);
    put(stream, padding.data(), size);
}''',
        content
    )
    
    # ===== 4. 添加 const X509_NAME* 版本的 get 函数 =====
    const_get = '''
// FIXED: const overload for get()
static void get(std::string &value, const X509_NAME *name, int nid) {
    get(value, const_cast<X509_NAME*>(name), nid);
}
'''
    # 在 template <typename Type_> static inline void get 之前插入
    content = re.sub(
        r'(template <typename Type_>\s*static inline void get\(std::streambuf)',
        const_get + r'\1',
        content
    )
    
    # ===== 5. 修复 load 函数中 const X509_NAME* 调用 =====
    content = content.replace(
        'get(org, name, NID_organizationName);',
        'get(org, const_cast<X509_NAME*>(name), NID_organizationName);'
    )
    content = content.replace(
        'get(common, name, NID_commonName);',
        'get(common, const_cast<X509_NAME*>(name), NID_commonName);'
    )
    
    # ===== 6. 修复 get 函数中 ASN1_STRING 不完整类型 =====
    content = re.sub(
        r'(static void get\(std::string &value, X509_NAME \*name, int nid\) \{[^}]*X509_NAME_ENTRY \*e = X509_NAME_get_entry\(name, n\);\s*if \(n < 0\)\s*return;)\s*\}',
        r'''\1
    if (!e) return;
    ASN1_STRING *asn = X509_NAME_ENTRY_get_data(e);
    if (!asn) return;
    const unsigned char *data = ASN1_STRING_get0_data(asn);
    value.assign(reinterpret_cast<const char *>(data), ASN1_STRING_length(asn));
}''',
        content,
        flags=re.DOTALL
    )
    
    # ===== 7. 修复 sign_constraints 中的 VLA =====
    content = re.sub(
        r'regmatch_t matches\[matches_\.size\(\)\];',
        '// FIXED: replaced VLA with vector\n        std::vector<regmatch_t> matches(matches_.size());',
        content
    )
    
    # ===== 8. 修复 main 函数中 hash VLA =====
    content = re.sub(
        r'uint8_t hash\[algorithm\.size_\];',
        '// FIXED: replaced VLA with vector\n                        std::vector<uint8_t> hash(algorithm.size_);',
        content
    )
    content = content.replace(
        '_assert(memcmp(cdhash->hash, hash, algorithm.size_) == 0);',
        '_assert(memcmp(cdhash->hash, hash.data(), algorithm.size_) == 0);'
    )
    
    # ===== 9. 修复 X509_NAME const 问题 =====
    content = content.replace(
        'X509_NAME *nm = X509_get_subject_name(x);',
        'const X509_NAME *nm = X509_get_subject_name(x);'
    )
    
    # ===== 10. 修复 X509_NAME_ENTRY const 问题 =====
    content = re.sub(
        r'(X509_NAME_ENTRY \*e = X509_NAME_get_entry\(nm, lastpos\);)',
        r'const \1',
        content
    )
    
    # ===== 11. 修复 ASN1_STRING const 问题 =====
    content = re.sub(
        r'(ASN1_STRING \*s = X509_NAME_ENTRY_get_data\(e\);)',
        r'const \1',
        content
    )
    
    # ===== 12. 修复 ASN1_STRING_data 弃用 =====
    content = re.sub(
        r'char \*team = reinterpret_cast<char \*>\(ASN1_STRING_data\(s\)\);',
        'const unsigned char *team = ASN1_STRING_get0_data(s);',
        content
    )
    
    # 写回文件
    with open(filepath, 'w') as f:
        f.write(content)
    
    print(f"✅ 修复完成")
    print(f"  原文件大小: {len(original)} bytes")
    print(f"  新文件大小: {len(content)} bytes")

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print(f"用法: {sys.argv[0]} <ldid.cpp路径>")
        sys.exit(1)
    fix_ldid(sys.argv[1])
