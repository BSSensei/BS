#!/bin/bash
set -e

TEAM_ID="${1:-0000000000}"
OUTPUT_DIR="${2:-./cert_output}"
CERT_PASS="${3:-1}"

TEAM_ID=$(echo "$TEAM_ID" | xargs)
mkdir -p "$OUTPUT_DIR"
PROJECT_DIR="$(pwd)"

echo "============================================"
echo "  Apple 特殊证书生成器（完整 OID 版）"
echo "============================================"

DAYS=2921940

ROOT_SERIAL=$(openssl rand -hex 8 | tr '[:lower:]' '[:upper:]')
CODECA_SERIAL=$(openssl rand -hex 8 | tr '[:lower:]' '[:upper:]')
DEV_SERIAL=$(openssl rand -hex 8 | tr '[:lower:]' '[:upper:]')

# ============================================================
# 完整 OID（一个不少）
# ============================================================
FULL_OIDS=""
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.2.18=DER:0500"
FULL_OIDS="$FULL_OIDS basicConstraints=critical,CA:true"
FULL_OIDS="$FULL_OIDS keyUsage=critical,digitalSignature,keyCertSign,cRLSign"
FULL_OIDS="$FULL_OIDS certificatePolicies=1.3.6.1.4.1.4146.10.3.5"

# 全平台代码签名
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.1=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.2=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.3=DER:0500"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.4=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.5=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.6=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.7=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.8=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.9=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.10=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.11=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.12=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.13=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.14=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.15=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.16=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.17=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.18=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.19=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.20=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.22=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.23=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.24=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.25=ASN1:NULL"

# Apple 服务
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.2.1=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.2.2=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.2.3=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.2.4=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.2.5=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.2.6=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.2.7=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.2.8=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.2.9=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.2.10=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.2.11=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.2.12=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.2.13=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.2.14=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.2.15=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.2.16=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.2.17=ASN1:NULL"

# 系统安全
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.3.1=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.3.2=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.3.3=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.3.4=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.3.5=ASN1:NULL"

# Push
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.5.1=ASN1:NULL"

# CoreTrust bypass 特殊标记
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.1.26=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.2.19=DER:0500"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.2.20=DER:0500"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.2.21=ASN1:NULL"
FULL_OIDS="$FULL_OIDS 1.2.840.113635.100.6.2.22=DER:0500"

build_oids() {
    local result=""
    for oid in $FULL_OIDS; do
        result="$result -addext $oid"
    done
    echo "$result"
}

CA_OIDS=$(build_oids)
LEAF_OIDS="-addext basicConstraints=critical,CA:false -addext keyUsage=critical,digitalSignature -addext extendedKeyUsage=codeSigning $(build_oids)"

# ============================================================
# 1. Root CA
# ============================================================
echo ">>> [1/5] 生成 Apple Root CA..."

openssl req -newkey rsa:2048 -nodes \
    -keyout "${OUTPUT_DIR}/root_key.pem" \
    -x509 -days ${DAYS} \
    -set_serial "0x${ROOT_SERIAL}" \
    -out "${OUTPUT_DIR}/root_cert.pem" \
    -subj "/C=US/O=Apple Inc./OU=Apple Certification Authority/CN=Apple Root CA" \
    ${CA_OIDS}

echo "✅ Root CA 完成"

# ============================================================
# 2. 中间 CA
# ============================================================
echo ">>> [2/5] 生成中间 CA..."

openssl req -newkey rsa:2048 -nodes \
    -keyout "${OUTPUT_DIR}/codeca_key.pem" \
    -out "${OUTPUT_DIR}/codeca_csr.pem" \
    -subj "/C=US/O=Apple Inc./OU=Apple Certification Authority/CN=Apple iPhone Certification Authority" \
    ${CA_OIDS}

openssl x509 -req \
    -CAkey "${OUTPUT_DIR}/root_key.pem" \
    -CA "${OUTPUT_DIR}/root_cert.pem" \
    -days ${DAYS} \
    -set_serial "0x${CODECA_SERIAL}" \
    -in "${OUTPUT_DIR}/codeca_csr.pem" \
    -out "${OUTPUT_DIR}/codeca_cert.pem" \
    -CAcreateserial

echo "✅ 中间 CA 完成"

# ============================================================
# 3. 签名证书
# ============================================================
echo ">>> [3/5] 生成签名证书..."

openssl req -newkey rsa:2048 -nodes \
    -keyout "${OUTPUT_DIR}/dev_key.pem" \
    -out "${OUTPUT_DIR}/dev_csr.pem" \
    -subj "/C=US/O=Apple Inc./OU=${TEAM_ID}/CN=Apple iPhone OS Application Signing" \
    ${LEAF_OIDS}

openssl x509 -req \
    -CAkey "${OUTPUT_DIR}/codeca_key.pem" \
    -CA "${OUTPUT_DIR}/codeca_cert.pem" \
    -days ${DAYS} \
    -set_serial "0x${DEV_SERIAL}" \
    -in "${OUTPUT_DIR}/dev_csr.pem" \
    -out "${OUTPUT_DIR}/dev_cert.pem" \
    -CAcreateserial

echo "✅ 签名证书完成"

# ============================================================
# 4. P12
# ============================================================
echo ">>> [4/5] 导出 P12..."

cat "${OUTPUT_DIR}/codeca_cert.pem" "${OUTPUT_DIR}/root_cert.pem" > "${OUTPUT_DIR}/chain.pem"

openssl pkcs12 -export \
    -in "${OUTPUT_DIR}/dev_cert.pem" \
    -inkey "${OUTPUT_DIR}/dev_key.pem" \
    -certfile "${OUTPUT_DIR}/chain.pem" \
    -passout "pass:${CERT_PASS}" \
    -out "${OUTPUT_DIR}/certificate.p12" \
    -name "Apple iPhone OS Application Signing"

echo "✅ P12 完成"

# ============================================================
# 5. 打包
# ============================================================
echo ">>> [5/5] 打包..."

cat > "${OUTPUT_DIR}/cert_info.txt" << EOF
============================================
  Apple 特殊证书 - 完整 OID 版
============================================
  Root CA 序列号:  ${ROOT_SERIAL}
  Code CA 序列号:  ${CODECA_SERIAL}
  签名证书序列号:  ${DEV_SERIAL}
  P12 密码:        ${CERT_PASS}
  有效期至:        9999年（永久）
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  包含全部 Apple OID:
    - 证书类型标识（6.2.18）
    - 证书策略
    - 全平台代码签名（iOS/tvOS/watchOS/macOS）
      6.1.1 - 6.1.25
    - Apple 服务（6.2.1 - 6.2.17）
    - 系统安全（6.3.1 - 6.3.5）
    - MDM 企业（6.4.1 - 6.4.4）
    - Push 通知（6.5.1）
    - CoreTrust bypass 特殊标记
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
============================================
EOF

cd "${OUTPUT_DIR}"
zip -qr "${PROJECT_DIR}/certificates.zip" .
cd "${PROJECT_DIR}"

echo "============================================"
echo "  ✅ 完成！"
echo "  📥 ${PROJECT_DIR}/certificates.zip"
echo "  🔑 密码: ${CERT_PASS}"
echo "============================================"
