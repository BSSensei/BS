#!/bin/bash
set -e

TEAM_ID="${1:-0000000000}"
OUTPUT_DIR="${2:-./cert_output}"
CERT_PASS="${3:-1}"

TEAM_ID=$(echo "$TEAM_ID" | xargs)
mkdir -p "$OUTPUT_DIR"
PROJECT_DIR="$(pwd)"

echo "============================================"
echo "  Apple 高仿证书生成器"
echo "============================================"

DAYS=2921940

ROOT_SERIAL=$(openssl rand -hex 8 | tr '[:lower:]' '[:upper:]')
CODECA_SERIAL=$(openssl rand -hex 8 | tr '[:lower:]' '[:upper:]')
DEV_SERIAL=$(openssl rand -hex 8 | tr '[:lower:]' '[:upper:]')

# ============================================================
# 生成完整 OID 列表
# ============================================================
PURE_OIDS="1.2.840.113635.100.6.2.18=DER:0500"

# 6.1.1 - 6.1.26（代码签名全平台）
for i in $(seq 1 26); do
    if [ "$i" = "3" ]; then
        PURE_OIDS="$PURE_OIDS 1.2.840.113635.100.6.1.$i=DER:0500"
    else
        PURE_OIDS="$PURE_OIDS 1.2.840.113635.100.6.1.$i=ASN1:NULL"
    fi
done

# 6.2.1 - 6.2.22（Apple 服务 + 特殊标记）
for i in $(seq 1 22); do
    case $i in
        18|19|20|22) PURE_OIDS="$PURE_OIDS 1.2.840.113635.100.6.2.$i=DER:0500" ;;
        *) PURE_OIDS="$PURE_OIDS 1.2.840.113635.100.6.2.$i=ASN1:NULL" ;;
    esac
done

# 6.3.1 - 6.3.5（系统安全）
for i in $(seq 1 5); do
    PURE_OIDS="$PURE_OIDS 1.2.840.113635.100.6.3.$i=ASN1:NULL"
done

# 6.5.1（Push）
PURE_OIDS="$PURE_OIDS 1.2.840.113635.100.6.5.1=ASN1:NULL"

V3_EXT=""
for oid in $PURE_OIDS; do
    V3_EXT="$V3_EXT -addext $oid"
done

CA_FIXED="-addext basicConstraints=critical,CA:true -addext keyUsage=critical,digitalSignature,keyCertSign,cRLSign -addext certificatePolicies=1.3.6.1.4.1.4146.10.3.5"

LEAF_FIXED="-addext basicConstraints=critical,CA:false -addext keyUsage=critical,digitalSignature -addext extendedKeyUsage=codeSigning -addext certificatePolicies=1.3.6.1.4.1.4146.10.3.5"

# ============================================================
# 1. Root CA
# ============================================================
echo ">>> [1/5] Root CA..."
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${OUTPUT_DIR}/root_key.pem" \
    -out "${OUTPUT_DIR}/root_cert.pem" \
    -subj "/C=US/O=Apple Inc./OU=Apple Certification Authority/CN=Apple Root CA" \
    -days ${DAYS} \
    -set_serial "0x${ROOT_SERIAL}" \
    ${CA_FIXED} ${V3_EXT}
echo "✅ Root CA"

# ============================================================
# 2. 中间 CA
# ============================================================
echo ">>> [2/5] 中间 CA..."
openssl req -new -newkey rsa:2048 -nodes \
    -keyout "${OUTPUT_DIR}/codeca_key.pem" \
    -out "${OUTPUT_DIR}/codeca_csr.pem" \
    -subj "/C=US/O=Apple Inc./OU=Apple Certification Authority/CN=Apple iPhone Certification Authority" \
    ${CA_FIXED} ${V3_EXT}

openssl x509 -req \
    -CAkey "${OUTPUT_DIR}/root_key.pem" \
    -CA "${OUTPUT_DIR}/root_cert.pem" \
    -in "${OUTPUT_DIR}/codeca_csr.pem" \
    -out "${OUTPUT_DIR}/codeca_cert.pem" \
    -days ${DAYS} \
    -set_serial "0x${CODECA_SERIAL}" \
    -CAcreateserial
echo "✅ 中间 CA"

# ============================================================
# 3. 签名证书
# ============================================================
echo ">>> [3/5] 签名证书..."
openssl req -new -newkey rsa:2048 -nodes \
    -keyout "${OUTPUT_DIR}/dev_key.pem" \
    -out "${OUTPUT_DIR}/dev_csr.pem" \
    -subj "/C=US/O=Apple Inc./OU=${TEAM_ID}/CN=Apple iPhone OS Application Signing" \
    ${LEAF_FIXED} ${V3_EXT}

openssl x509 -req \
    -CAkey "${OUTPUT_DIR}/codeca_key.pem" \
    -CA "${OUTPUT_DIR}/codeca_cert.pem" \
    -in "${OUTPUT_DIR}/dev_csr.pem" \
    -out "${OUTPUT_DIR}/dev_cert.pem" \
    -days ${DAYS} \
    -set_serial "0x${DEV_SERIAL}" \
    -CAcreateserial
echo "✅ 签名证书"

# ============================================================
# 4. P12 + Base64
# ============================================================
echo ">>> [4/5] P12 + Base64..."
cat "${OUTPUT_DIR}/codeca_cert.pem" "${OUTPUT_DIR}/root_cert.pem" > "${OUTPUT_DIR}/chain.pem"

openssl pkcs12 -export \
    -in "${OUTPUT_DIR}/dev_cert.pem" \
    -inkey "${OUTPUT_DIR}/dev_key.pem" \
    -certfile "${OUTPUT_DIR}/chain.pem" \
    -passout "pass:${CERT_PASS}" \
    -out "${OUTPUT_DIR}/certificate.p12" \
    -name "Apple iPhone OS Application Signing"

openssl base64 -in "${OUTPUT_DIR}/certificate.p12" -out "${OUTPUT_DIR}/certificate.p12.b64"
for f in "${OUTPUT_DIR}"/*.pem; do
    openssl base64 -in "$f" -out "${f}.b64"
done
echo "✅ Base64"

# ============================================================
# 5. 打包
# ============================================================
echo ">>> [5/5] 打包..."
cat > "${OUTPUT_DIR}/cert_info.txt" << EOF
============================================
  Apple 高仿证书
============================================
  Team ID:  ${TEAM_ID}
  P12 密码: ${CERT_PASS}
  有效期:   9999年
  .b64 = Base64 编码
  OID 总数: 57（6.1.1-26 + 6.2.1-22 + 6.3.1-5 + 6.5.1 + 6.2.18）
============================================
EOF

cd "${OUTPUT_DIR}"
zip -qr "${PROJECT_DIR}/certificates.zip" .
cd "${PROJECT_DIR}"

echo "============================================"
echo "  ✅ 完成"
echo "  📥 ${PROJECT_DIR}/certificates.zip"
echo "  🔑 密码: ${CERT_PASS}"
echo "============================================"
