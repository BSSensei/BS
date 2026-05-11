#!/bin/bash
set -e

TEAM_ID="${1:-0000000000}"
OUTPUT_DIR="${2:-./cert_output}"
CERT_PASS="${3:-1}"

TEAM_ID=$(echo "$TEAM_ID" | xargs)
mkdir -p "$OUTPUT_DIR"

echo "============================================"
echo "  Apple 高仿证书生成器"
echo "  Team ID:  $TEAM_ID"
echo "  密码:     $CERT_PASS"
echo "  有效期:   2126年"
echo "============================================"

# ============================================================
# CA 证书的 OID（CA:true）
# ============================================================
CA_OIDS="-addext 1.2.840.113635.100.6.2.18=DER:0500"
CA_OIDS="$CA_OIDS -addext basicConstraints=critical,CA:true"
CA_OIDS="$CA_OIDS -addext keyUsage=critical,digitalSignature,keyCertSign,cRLSign"
CA_OIDS="$CA_OIDS -addext certificatePolicies=1.3.6.1.4.1.4146.10.3.5"
CA_OIDS="$CA_OIDS -addext 1.2.840.113635.100.6.1.2=ASN1:NULL"
CA_OIDS="$CA_OIDS -addext 1.2.840.113635.100.6.1.3=DER:0500"
CA_OIDS="$CA_OIDS -addext 1.2.840.113635.100.6.1.4=ASN1:NULL"
CA_OIDS="$CA_OIDS -addext 1.2.840.113635.100.6.1.5=ASN1:NULL"
CA_OIDS="$CA_OIDS -addext 1.2.840.113635.100.6.1.6=ASN1:NULL"
CA_OIDS="$CA_OIDS -addext 1.2.840.113635.100.6.1.7=ASN1:NULL"
CA_OIDS="$CA_OIDS -addext 1.2.840.113635.100.6.1.8=ASN1:NULL"
CA_OIDS="$CA_OIDS -addext 1.2.840.113635.100.6.1.9=ASN1:NULL"
CA_OIDS="$CA_OIDS -addext 1.2.840.113635.100.6.1.10=ASN1:NULL"
CA_OIDS="$CA_OIDS -addext 1.2.840.113635.100.6.1.11=ASN1:NULL"
CA_OIDS="$CA_OIDS -addext 1.2.840.113635.100.6.1.12=ASN1:NULL"
CA_OIDS="$CA_OIDS -addext 1.2.840.113635.100.6.1.13=ASN1:NULL"
CA_OIDS="$CA_OIDS -addext 1.2.840.113635.100.6.1.14=ASN1:NULL"
CA_OIDS="$CA_OIDS -addext 1.2.840.113635.100.6.1.15=ASN1:NULL"
CA_OIDS="$CA_OIDS -addext 1.2.840.113635.100.6.1.16=ASN1:NULL"
CA_OIDS="$CA_OIDS -addext 1.2.840.113635.100.6.1.17=ASN1:NULL"
CA_OIDS="$CA_OIDS -addext 1.2.840.113635.100.6.1.18=ASN1:NULL"
CA_OIDS="$CA_OIDS -addext 1.2.840.113635.100.6.1.19=ASN1:NULL"
CA_OIDS="$CA_OIDS -addext 1.2.840.113635.100.6.1.20=ASN1:NULL"
CA_OIDS="$CA_OIDS -addext 1.2.840.113635.100.6.2.1=ASN1:NULL"
CA_OIDS="$CA_OIDS -addext 1.2.840.113635.100.6.2.6=ASN1:NULL"
CA_OIDS="$CA_OIDS -addext 1.2.840.113635.100.6.5.1=ASN1:NULL"

# ============================================================
# 叶子证书的 OID（CA:false + codeSigning）
# ============================================================
LEAF_OIDS="-addext basicConstraints=critical,CA:false"
LEAF_OIDS="$LEAF_OIDS -addext keyUsage=critical,digitalSignature"
LEAF_OIDS="$LEAF_OIDS -addext extendedKeyUsage=codeSigning"
LEAF_OIDS="$LEAF_OIDS -addext 1.2.840.113635.100.6.2.18=DER:0500"
LEAF_OIDS="$LEAF_OIDS -addext certificatePolicies=1.3.6.1.4.1.4146.10.3.5"
LEAF_OIDS="$LEAF_OIDS -addext 1.2.840.113635.100.6.1.2=ASN1:NULL"
LEAF_OIDS="$LEAF_OIDS -addext 1.2.840.113635.100.6.1.3=DER:0500"
LEAF_OIDS="$LEAF_OIDS -addext 1.2.840.113635.100.6.1.4=ASN1:NULL"
LEAF_OIDS="$LEAF_OIDS -addext 1.2.840.113635.100.6.1.5=ASN1:NULL"
LEAF_OIDS="$LEAF_OIDS -addext 1.2.840.113635.100.6.1.6=ASN1:NULL"
LEAF_OIDS="$LEAF_OIDS -addext 1.2.840.113635.100.6.1.7=ASN1:NULL"
LEAF_OIDS="$LEAF_OIDS -addext 1.2.840.113635.100.6.1.8=ASN1:NULL"
LEAF_OIDS="$LEAF_OIDS -addext 1.2.840.113635.100.6.1.9=ASN1:NULL"
LEAF_OIDS="$LEAF_OIDS -addext 1.2.840.113635.100.6.1.10=ASN1:NULL"
LEAF_OIDS="$LEAF_OIDS -addext 1.2.840.113635.100.6.1.11=ASN1:NULL"
LEAF_OIDS="$LEAF_OIDS -addext 1.2.840.113635.100.6.1.12=ASN1:NULL"
LEAF_OIDS="$LEAF_OIDS -addext 1.2.840.113635.100.6.1.13=ASN1:NULL"
LEAF_OIDS="$LEAF_OIDS -addext 1.2.840.113635.100.6.1.14=ASN1:NULL"
LEAF_OIDS="$LEAF_OIDS -addext 1.2.840.113635.100.6.1.15=ASN1:NULL"
LEAF_OIDS="$LEAF_OIDS -addext 1.2.840.113635.100.6.1.16=ASN1:NULL"
LEAF_OIDS="$LEAF_OIDS -addext 1.2.840.113635.100.6.1.17=ASN1:NULL"
LEAF_OIDS="$LEAF_OIDS -addext 1.2.840.113635.100.6.1.18=ASN1:NULL"
LEAF_OIDS="$LEAF_OIDS -addext 1.2.840.113635.100.6.1.19=ASN1:NULL"
LEAF_OIDS="$LEAF_OIDS -addext 1.2.840.113635.100.6.1.20=ASN1:NULL"
LEAF_OIDS="$LEAF_OIDS -addext 1.2.840.113635.100.6.2.1=ASN1:NULL"
LEAF_OIDS="$LEAF_OIDS -addext 1.2.840.113635.100.6.2.6=ASN1:NULL"
LEAF_OIDS="$LEAF_OIDS -addext 1.2.840.113635.100.6.5.1=ASN1:NULL"

# 有效期天数（2126年 ≈ 36500天）
DAYS=36500

# ============================================================
# 1. Root CA
# ============================================================
echo ">>> [1/6] 生成 Apple Root CA..."

openssl req -newkey rsa:2048 -nodes \
    -keyout "${OUTPUT_DIR}/root_key.pem" \
    -x509 -days ${DAYS} \
    -out "${OUTPUT_DIR}/root_cert.pem" \
    -subj "/C=US/O=Apple Inc./CN=Apple Root CA" \
    ${CA_OIDS}

echo "✅ Root CA → root_key.pem + root_cert.pem"

# ============================================================
# 2. 中间 CA
# ============================================================
echo ">>> [2/6] 生成中间 CA..."

openssl req -newkey rsa:2048 -nodes \
    -keyout "${OUTPUT_DIR}/codeca_key.pem" \
    -out "${OUTPUT_DIR}/codeca_csr.pem" \
    -subj "/C=US/O=Apple Inc./CN=Apple iPhone Certification Authority" \
    ${CA_OIDS}

openssl x509 -req \
    -CAkey "${OUTPUT_DIR}/root_key.pem" \
    -CA "${OUTPUT_DIR}/root_cert.pem" \
    -days ${DAYS} \
    -in "${OUTPUT_DIR}/codeca_csr.pem" \
    -out "${OUTPUT_DIR}/codeca_cert.pem" \
    -CAcreateserial -copy_extensions=copy

echo "✅ 中间 CA → codeca_key.pem + codeca_cert.pem"

# ============================================================
# 3. 签名证书（叶子）
# ============================================================
echo ">>> [3/6] 生成签名证书..."

openssl req -newkey rsa:2048 -nodes \
    -keyout "${OUTPUT_DIR}/dev_key.pem" \
    -out "${OUTPUT_DIR}/dev_csr.pem" \
    -subj "/C=US/O=Apple Inc./OU=${TEAM_ID}/CN=Apple iPhone OS Application Signing" \
    ${LEAF_OIDS}

openssl x509 -req \
    -CAkey "${OUTPUT_DIR}/codeca_key.pem" \
    -CA "${OUTPUT_DIR}/codeca_cert.pem" \
    -days ${DAYS} \
    -in "${OUTPUT_DIR}/dev_csr.pem" \
    -out "${OUTPUT_DIR}/dev_cert.pem" \
    -CAcreateserial -copy_extensions=copy

echo "✅ 签名证书 → dev_key.pem + dev_cert.pem"

# ============================================================
# 4. 导出 P12
# ============================================================
echo ">>> [4/6] 导出 P12..."

cat "${OUTPUT_DIR}/codeca_cert.pem" "${OUTPUT_DIR}/root_cert.pem" > "${OUTPUT_DIR}/chain.pem"

openssl pkcs12 -export \
    -in "${OUTPUT_DIR}/dev_cert.pem" \
    -inkey "${OUTPUT_DIR}/dev_key.pem" \
    -certfile "${OUTPUT_DIR}/chain.pem" \
    -passout "pass:${CERT_PASS}" \
    -out "${OUTPUT_DIR}/certificate.p12" \
    -name "Apple iPhone OS Application Signing"

echo "✅ P12 → certificate.p12"

# ============================================================
# 5. 生成证书信息
# ============================================================
echo ">>> [5/6] 生成证书信息..."

cat > "${OUTPUT_DIR}/cert_info.txt" << EOF
============================================
  Apple 高仿证书 - 全平台代码签名
============================================
  生成时间:   $(date)
  Team ID:    ${TEAM_ID}
  P12 密码:   ${CERT_PASS}
  有效期至:   2126年（${DAYS}天）

  证书链:
    root_cert.pem           - Apple Root CA
    codeca_cert.pem         - Apple iPhone Certification Authority
    dev_cert.pem            - Apple iPhone OS Application Signing

  私钥:
    root_key.pem            - Root CA 私钥
    codeca_key.pem          - 中间 CA 私钥
    dev_key.pem             - 签名证书私钥

  签名请求:
    codeca_csr.pem          - 中间 CA CSR
    dev_csr.pem             - 签名证书 CSR

  导出:
    certificate.p12         - P12 格式（含完整证书链）

  包含全部 Apple OID（iOS/tvOS/watchOS/macOS）
============================================
EOF

echo ""
echo "============================================"
echo "  ✅ 全部证书生成完成！"
echo ""
echo "  📁 输出目录: ${OUTPUT_DIR}/"
echo "  📦  P12:     certificate.p12"
echo "  🔑  密码:    ${CERT_PASS}"
echo "  📅  有效期:  2126年"
echo ""
echo "  保留的文件:"
echo "    root_cert.pem    - Apple Root CA 证书"
echo "    root_key.pem     - Apple Root CA 私钥"
echo "    codeca_cert.pem  - 中间 CA 证书"
echo "    codeca_key.pem   - 中间 CA 私钥"
echo "    codeca_csr.pem   - 中间 CA 签名请求"
echo "    dev_cert.pem     - 代码签名证书"
echo "    dev_key.pem      - 代码签名私钥"
echo "    dev_csr.pem      - 代码签名请求"
echo "    chain.pem        - 完整证书链"
echo "    certificate.p12  - P12 导出"
echo "============================================"
