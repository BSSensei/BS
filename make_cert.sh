#!/bin/bash

TEAM_ID="${1:-Apple Certification Authority}"
OUTPUT_DIR="${2:-./cert_output}"
CERT_PASS="${3:-1}"

TEAM_ID=$(echo "$TEAM_ID" | xargs)
mkdir -p "$OUTPUT_DIR"
PROJECT_DIR="$(pwd)"

OPENSSL="$(brew --prefix openssl@3)/bin/openssl"
export PATH="$(brew --prefix openssl@3)/bin:$PATH"

echo "============================================"
echo "  Apple 高仿证书生成器"
echo "============================================"

DAYS=2912000

ROOT_SERIAL=$($OPENSSL rand -hex 8 | tr '[:lower:]' '[:upper:]')
CODECA_SERIAL=$($OPENSSL rand -hex 8 | tr '[:lower:]' '[:upper:]')
DEV_SERIAL=$($OPENSSL rand -hex 8 | tr '[:lower:]' '[:upper:]')

# ============================================================
# CA 配置文件（使用正确的 Apple 证书策略 OID）
# ============================================================
cat > /tmp/ca_oid.conf << 'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_ca
prompt = no

[ req_distinguished_name ]
C = US
O = Apple Inc.
OU = Apple Certification Authority
CN = Apple Root CA

[ v3_ca ]
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, keyCertSign, cRLSign
certificatePolicies = 1.2.840.113635.100.5.1
# 6.1.1 - 6.1.26（全部 DER:0500）
for i in $(seq 1 26); do

  echo "1.2.840.113635.100.6.1.${i} = DER:05:00" >> /tmp/ca_oid.conf
done

# 6.2.1 - 6.2.17（ASN1:NULL）
for i in $(seq 1 17); do
    echo "1.2.840.113635.100.6.2.${i} = ASN1:NULL" >> /tmp/ca_oid.conf
done

# 6.3.1 - 6.3.5
for i in $(seq 1 5); do
    echo "1.2.840.113635.100.6.3.${i} = ASN1:NULL" >> /tmp/ca_oid.conf
done

echo "1.2.840.113635.100.6.5.1 = ASN1:NULL" >> /tmp/ca_oid.conf

# ============================================================
# 叶子证书配置文件
# ============================================================
cat > /tmp/leaf_oid.conf << 'EOF'
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_leaf
prompt = no

[ req_distinguished_name ]
C = US
O = Apple Inc.
OU = Apple Certification Authority
CN = Apple Development

[ v3_leaf ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
certificatePolicies = 1.2.840.113635.100.5.1
CPS = https://www.apple.com/certificateauthority/
1.2.840.113635.100.6.2.18 = DER:05:00
EOF

for i in $(seq 1 26); do
    echo "1.2.840.113635.100.6.1.${i} = DER:05:00" >> /tmp/leaf_oid.conf
done

for i in $(seq 1 17); do
    echo "1.2.840.113635.100.6.2.${i} = ASN1:NULL" >> /tmp/leaf_oid.conf
done

for i in $(seq 1 5); do
    echo "1.2.840.113635.100.6.3.${i} = ASN1:NULL" >> /tmp/leaf_oid.conf
done

echo "1.2.840.113635.100.6.5.1 = ASN1:NULL" >> /tmp/leaf_oid.conf

# 签发用配置
cp /tmp/ca_oid.conf /tmp/ca_issuer.conf
cp /tmp/leaf_oid.conf /tmp/leaf_issuer.conf

# ============================================================
# 1. Root CA
# ============================================================
echo ">>> [1/5] Root CA..."
$OPENSSL req -x509 -newkey rsa:2048 -nodes \
    -keyout "${OUTPUT_DIR}/root_key.pem" \
    -out "${OUTPUT_DIR}/root_cert.pem" \
    -config /tmp/ca_oid.conf \
    -days ${DAYS} \
    -set_serial "0x${ROOT_SERIAL}" \
    -extensions v3_ca || { echo "❌ Root CA 失败"; exit 1; }
echo "✅ Root CA"

# ============================================================
# 2. 中间 CA
# ============================================================
echo ">>> [2/5] 中间 CA..."
$OPENSSL req -new -newkey rsa:2048 -nodes \
    -keyout "${OUTPUT_DIR}/codeca_key.pem" \
    -out "${OUTPUT_DIR}/codeca_csr.pem" \
    -subj "/C=US/O=Apple Inc./OU=Apple Certification Authority/CN=Apple iPhone Certification Authority" \
    -reqexts v3_ca \
    -config /tmp/ca_oid.conf || { echo "❌ 中间 CA CSR 失败"; exit 1; }

$OPENSSL x509 -req \
    -CAkey "${OUTPUT_DIR}/root_key.pem" \
    -CA "${OUTPUT_DIR}/root_cert.pem" \
    -in "${OUTPUT_DIR}/codeca_csr.pem" \
    -out "${OUTPUT_DIR}/codeca_cert.pem" \
    -days ${DAYS} \
    -set_serial "0x${CODECA_SERIAL}" \
    -extfile /tmp/ca_issuer.conf \
    -extensions v3_ca \
    -CAcreateserial || { echo "❌ 中间 CA 签发失败"; exit 1; }
echo "✅ 中间 CA"

# ============================================================
# 3. 签名证书
# ============================================================
echo ">>> [3/5] 签名证书..."
$OPENSSL req -new -newkey rsa:2048 -nodes \
    -keyout "${OUTPUT_DIR}/dev_key.pem" \
    -out "${OUTPUT_DIR}/dev_csr.pem" \
    -config /tmp/leaf_oid.conf || { echo "❌ 签名 CSR 失败"; exit 1; }

$OPENSSL x509 -req \
    -CAkey "${OUTPUT_DIR}/codeca_key.pem" \
    -CA "${OUTPUT_DIR}/codeca_cert.pem" \
    -in "${OUTPUT_DIR}/dev_csr.pem" \
    -out "${OUTPUT_DIR}/dev_cert.pem" \
    -days ${DAYS} \
    -set_serial "0x${DEV_SERIAL}" \
    -extfile /tmp/leaf_issuer.conf \
    -extensions v3_leaf \
    -CAcreateserial || { echo "❌ 签名证书签发失败"; exit 1; }
echo "✅ 签名证书"

# ============================================================
# 4. P12 + Base64
# ============================================================
echo ">>> [4/5] P12 + Base64..."
cat "${OUTPUT_DIR}/codeca_cert.pem" "${OUTPUT_DIR}/root_cert.pem" > "${OUTPUT_DIR}/chain.pem" || true

$OPENSSL pkcs12 -export \
    -in "${OUTPUT_DIR}/dev_cert.pem" \
    -inkey "${OUTPUT_DIR}/dev_key.pem" \
    -certfile "${OUTPUT_DIR}/chain.pem" \
    -passout "pass:${CERT_PASS}" \
    -out "${OUTPUT_DIR}/certificate.p12" \
    -name "Apple Development" || { echo "❌ P12 导出失败"; exit 1; }

$OPENSSL base64 -in "${OUTPUT_DIR}/certificate.p12" -out "${OUTPUT_DIR}/certificate.p12.b64" || true
for f in "${OUTPUT_DIR}"/*.pem; do
    $OPENSSL base64 -in "$f" -out "${f}.b64" 2>/dev/null || true
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
  有效期:   ~8000年
  证书策略: 1.2.840.113635.100.5.1
  CPS:      https://www.apple.com/certificateauthority/
  6.1.1-6.1.26 = DER:0500
  6.2.1-6.2.18 = ASN1:NULL (6.2.18=DER:0500)
  6.3.1-6.3.5  = ASN1:NULL
  6.5.1        = ASN1:NULL (Push)
============================================
EOF

cd "${OUTPUT_DIR}"
zip -qr "${PROJECT_DIR}/certificates.zip" . || { echo "❌ 打包失败"; exit 1; }
cd "${PROJECT_DIR}"

echo "============================================"
echo "  ✅ 完成"
echo "  📥 ${PROJECT_DIR}/certificates.zip"
echo "  🔑 密码: ${CERT_PASS}"
echo "============================================"
