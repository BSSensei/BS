#!/bin/bash
set -e

TEAM_ID="${1:-Apple Certification Authority}"
OUTPUT_DIR="${2:-./cert_output}"
CERT_PASS="${3:-}"

TEAM_ID=$(echo "$TEAM_ID" | xargs)
mkdir -p "$OUTPUT_DIR"

export PATH="/opt/homebrew/opt/openssl@3/bin:$PATH"

echo "============================================"
echo "  Apple 高仿证书生成器"
echo "============================================"

# ============================================================
# 1. Root CA
# ============================================================
echo ">>> [1/3] Root CA..."
openssl req -newkey rsa:2048 -nodes \
    -keyout "${OUTPUT_DIR}/root_key.pem" \
    -x509 -days 2912000 \
    -out "${OUTPUT_DIR}/root_cert.pem" \
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
    -keyout "${OUTPUT_DIR}/codeca_key.pem" \
    -out "${OUTPUT_DIR}/codeca_csr.pem" \
    -subj "/C=US/O=Apple Inc./OU=Apple Certification Authority/CN=Apple iPhone Certification Authority" \
    -addext "1.2.840.113635.100.6.2.18=DER:0500" \
    -addext "basicConstraints=critical,CA:true" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"

openssl x509 -req \
    -CAkey "${OUTPUT_DIR}/root_key.pem" \
    -CA "${OUTPUT_DIR}/root_cert.pem" \
    -days 2912000 \
    -in "${OUTPUT_DIR}/codeca_csr.pem" \
    -out "${OUTPUT_DIR}/codeca_cert.pem" \
    -CAcreateserial
echo "✅ 中间 CA"

# ============================================================
# 3. 签名证书
# ============================================================
echo ">>> [3/3] 签名证书..."
openssl req -newkey rsa:2048 -nodes \
    -keyout "${OUTPUT_DIR}/dev_key.pem" \
    -out "${OUTPUT_DIR}/dev_csr.pem" \
    -subj "/C=US/O=Apple Inc./OU=${TEAM_ID}/CN=Apple Development" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -addext "1.2.840.113635.100.6.1.3=DER:0500"

openssl x509 -req \
    -CAkey "${OUTPUT_DIR}/codeca_key.pem" \
    -CA "${OUTPUT_DIR}/codeca_cert.pem" \
    -days 2912000 \
    -in "${OUTPUT_DIR}/dev_csr.pem" \
    -out "${OUTPUT_DIR}/dev_cert.pem" \
    -CAcreateserial
echo "✅ 签名证书"

# ============================================================
# 4. 导出 P12 + Base64
# ============================================================
echo ">>> 导出 P12..."
cat "${OUTPUT_DIR}/codeca_cert.pem" "${OUTPUT_DIR}/root_cert.pem" > "${OUTPUT_DIR}/chain.pem"

openssl pkcs12 -export \
    -in "${OUTPUT_DIR}/dev_cert.pem" \
    -inkey "${OUTPUT_DIR}/dev_key.pem" \
    -certfile "${OUTPUT_DIR}/chain.pem" \
    -keypbe NONE -certpbe NONE \
    -passout "pass:${CERT_PASS}" \
    -out "${OUTPUT_DIR}/certificate.p12" \
    -name "Apple Development"

openssl base64 -in "${OUTPUT_DIR}/certificate.p12" -out "${OUTPUT_DIR}/certificate.p12.b64"
for f in "${OUTPUT_DIR}"/*.pem; do
    openssl base64 -in "$f" -out "${f}.b64"
done
echo "✅ P12 + Base64"

# ============================================================
# 5. 生成完整证书链 TXT
# ============================================================
echo ">>> 生成证书链 TXT..."

{
    echo "============================================"
    echo "  完整证书链"
    echo "============================================"
    echo ""
    echo "=== Apple Root CA ==="
    openssl x509 -in "${OUTPUT_DIR}/root_cert.pem" -text -noout
    echo ""
    echo "=== Apple iPhone Certification Authority ==="
    openssl x509 -in "${OUTPUT_DIR}/codeca_cert.pem" -text -noout
    echo ""
    echo "=== Apple Development (签名证书) ==="
    openssl x509 -in "${OUTPUT_DIR}/dev_cert.pem" -text -noout
} > "${OUTPUT_DIR}/certificate_chain.txt"

echo "✅ 证书链 TXT"

# ============================================================
# 6. 打包
# ============================================================
echo ">>> 打包..."
cat > "${OUTPUT_DIR}/cert_info.txt" << EOF
============================================
  Apple 高仿证书
============================================
  Team ID:  ${TEAM_ID}
  密码:     ${CERT_PASS}
  有效期:   ~8000年

  文件列表:
    root_cert.pem        - Apple Root CA
    codeca_cert.pem      - Apple iPhone Certification Authority
    dev_cert.pem         - Apple Development (签名证书)
    certificate.p12      - P12 格式（含完整证书链）
    certificate_chain.txt- 完整证书链（含各层级详细信息）
    *.b64                - 所有文件的 Base64 编码
============================================
EOF

cd "${OUTPUT_DIR}"
zip -qr "../certificates.zip" .
cd ..

echo "============================================"
echo "  ✅ 完成 → certificates.zip"
echo "  🔑 密码: ${CERT_PASS}"
echo "============================================"
