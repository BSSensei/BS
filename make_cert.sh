#!/bin/bash
set -e

TEAM_ID="${1:-0000000000}"
OUTPUT_DIR="${2:-./cert_output}"
CERT_PASS="${3:-1}"

TEAM_ID=$(echo "$TEAM_ID" | xargs)
mkdir -p "$OUTPUT_DIR"
PROJECT_DIR="$(pwd)"

export PATH="/opt/homebrew/opt/openssl@3/bin:$PATH"

echo "============================================"
echo "  Apple 高仿证书生成器（CoreTrust 优化）"
echo "============================================"

# ============================================================
# 1. Root CA
# ============================================================
echo ">>> [1/3] Root CA..."
openssl req -newkey rsa:2048 -nodes \
    -keyout "${OUTPUT_DIR}/root_key.key" \
    -x509 -days 2912000 \
    -out "${OUTPUT_DIR}/root_cert.crt" \
    -subj "/C=US/O=Apple Inc./OU=Apple Certification Authority/CN=Apple Root CA" \
    -addext "1.2.840.113635.100.6.2.18=DER:0500" \
    -addext "basicConstraints=critical,CA:true" \
    -addext "keyUsage=critical,digitalSignature,keyCertSign,cRLSign"
echo "✅ Root CA"

# ============================================================
# 2. 中间 CA
# ============================================================
echo ">>> [2/3] 中间 CA..."
openssl req -newkey rsa:2048 -nodes \
    -keyout "${OUTPUT_DIR}/codeca_key.key" \
    -out "${OUTPUT_DIR}/codeca_csr.csr" \
    -subj "/C=US/O=Apple Inc./OU=Apple Certification Authority/CN=Apple iPhone Certification Authority" \
    -addext "1.2.840.113635.100.6.2.18=DER:0500" \
    -addext "basicConstraints=critical,CA:true" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"

openssl x509 -req \
    -CAkey "${OUTPUT_DIR}/root_key.key" \
    -CA "${OUTPUT_DIR}/root_cert.crt" \
    -days 2912000 \
    -in "${OUTPUT_DIR}/codeca_csr.csr" \
    -out "${OUTPUT_DIR}/codeca_cert.crt" \
    -CAcreateserial
echo "✅ 中间 CA"

# ============================================================
# 3. 签名证书（含 CoreTrust 关键 OID）
# ============================================================
echo ">>> [3/3] 签名证书..."
openssl req -newkey rsa:2048 -nodes \
    -keyout "${OUTPUT_DIR}/dev_key.key" \
    -out "${OUTPUT_DIR}/dev_csr.csr" \
    -subj "/C=US/O=Apple Inc./OU=${TEAM_ID}/CN=Apple Development" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -addext "1.2.840.113635.100.6.1.3=DER:0500" \
    -addext "1.2.840.113635.100.6.1.2=ASN1:NULL" \
    -addext "1.2.840.113635.100.6.1.4=ASN1:NULL" \
    -addext "1.2.840.113635.100.6.2.1=ASN1:NULL" \
    -addext "1.2.840.113635.100.6.2.6=ASN1:NULL" \
    -addext "1.2.840.113635.100.6.2.18=DER:0500" \
    -addext "1.2.840.113635.100.6.1.19=ASN1:NULL"

openssl x509 -req \
    -CAkey "${OUTPUT_DIR}/codeca_key.key" \
    -CA "${OUTPUT_DIR}/codeca_cert.crt" \
    -days 2912000 \
    -in "${OUTPUT_DIR}/dev_csr.csr" \
    -out "${OUTPUT_DIR}/dev_cert.crt" \
    -CAcreateserial
echo "✅ 签名证书"

# ============================================================
# 4. P12 导出
# ============================================================
echo ">>> 导出 P12..."

# 单独身份 P12（签名+查看用）
openssl pkcs12 -export \
    -in "${OUTPUT_DIR}/dev_cert.crt" \
    -inkey "${OUTPUT_DIR}/dev_key.key" \
    -keypbe NONE -certpbe NONE \
    -passout "pass:${CERT_PASS}" \
    -out "${OUTPUT_DIR}/standalone.p12" \
    -name "Apple Development"

# 完整链 P12
cat "${OUTPUT_DIR}/codeca_cert.crt" "${OUTPUT_DIR}/root_cert.crt" > "${OUTPUT_DIR}/chain.crt"

openssl pkcs12 -export \
    -in "${OUTPUT_DIR}/dev_cert.crt" \
    -inkey "${OUTPUT_DIR}/dev_key.key" \
    -certfile "${OUTPUT_DIR}/chain.crt" \
    -keypbe NONE -certpbe NONE \
    -passout "pass:${CERT_PASS}" \
    -out "${OUTPUT_DIR}/fullchain.p12" \
    -name "Apple Development CA"

echo "✅ P12"

# ============================================================
# 5. Base64
# ============================================================
echo ">>> Base64..."
for f in "${OUTPUT_DIR}"/*.crt "${OUTPUT_DIR}"/*.key "${OUTPUT_DIR}"/*.csr "${OUTPUT_DIR}"/*.p12; do
    [ -f "$f" ] && openssl base64 -in "$f" -out "${f}.b64"
done
echo "✅ Base64"

# ============================================================
# 6. 证书链 TXT
# ============================================================
echo ">>> 证书链 TXT..."
{
    echo "============================================"
    echo "  完整证书链"
    echo "============================================"
    echo ""
    echo "=== Apple Root CA ==="
    openssl x509 -in "${OUTPUT_DIR}/root_cert.crt" -text -noout
    echo ""
    echo "=== Apple iPhone Certification Authority ==="
    openssl x509 -in "${OUTPUT_DIR}/codeca_cert.crt" -text -noout
    echo ""
    echo "=== Apple Development ==="
    openssl x509 -in "${OUTPUT_DIR}/dev_cert.crt" -text -noout
} > "${OUTPUT_DIR}/certificate_chain.txt"
echo "✅ 证书链 TXT"

# ============================================================
# 7. 打包
# ============================================================
echo ">>> 打包..."
cat > "${OUTPUT_DIR}/info.txt" << EOF
============================================
  Apple 高仿证书（CoreTrust 优化）
============================================
  密码:     ${CERT_PASS}
  有效期:   ~8000年

  CoreTrust 关键 OID:
    6.1.3   - iOS 代码签名
    6.1.2   - 开发者 ID
    6.1.4   - 描述文件签名
    6.2.1   - WWDR 标记
    6.2.6   - 开发者 CA
    6.2.18  - 证书类型
    6.1.19  - CPS 文档确认
============================================
EOF

cd "${OUTPUT_DIR}"
zip -qr "${PROJECT_DIR}/certificates.zip" .
cd "${PROJECT_DIR}"

echo "============================================"
echo "  ✅ certificates.zip"
echo "  🔑 密码: ${CERT_PASS}"
echo "  📱 standalone.p12 → 签名 + 设置查看"
echo "============================================"
