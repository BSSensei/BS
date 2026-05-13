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
# 3. 签名证书
# ============================================================
echo ">>> [3/3] 签名证书..."
openssl req -newkey rsa:2048 -nodes \
    -keyout "${OUTPUT_DIR}/dev_key.key" \
    -out "${OUTPUT_DIR}/dev_csr.csr" \
    -subj "/C=US/O=Apple Inc./OU=${TEAM_ID}/CN=Apple Development" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -addext "1.2.840.113635.100.6.1.3=DER:0500"

openssl x509 -req \
    -CAkey "${OUTPUT_DIR}/codeca_key.key" \
    -CA "${OUTPUT_DIR}/codeca_cert.crt" \
    -days 2912000 \
    -in "${OUTPUT_DIR}/dev_csr.csr" \
    -out "${OUTPUT_DIR}/dev_cert.crt" \
    -CAcreateserial
echo "✅ 签名证书"

# ============================================================
# 4. 导出 P12
# ============================================================
echo ">>> 导出 P12..."

# 证书链文件
cat "${OUTPUT_DIR}/codeca_cert.crt" "${OUTPUT_DIR}/root_cert.crt" > "${OUTPUT_DIR}/chain.crt"

# 完整证书链 P12（代码签名用）
openssl pkcs12 -export \
    -in "${OUTPUT_DIR}/dev_cert.crt" \
    -inkey "${OUTPUT_DIR}/dev_key.key" \
    -certfile "${OUTPUT_DIR}/chain.crt" \
    -keypbe NONE -certpbe NONE \
    -passout "pass:${CERT_PASS}" \
    -out "${OUTPUT_DIR}/fullchain.p12" \
    -name "Apple Development"

# 单独身份 P12（设置查看用）
openssl pkcs12 -export \
    -in "${OUTPUT_DIR}/dev_cert.crt" \
    -inkey "${OUTPUT_DIR}/dev_key.key" \
    -keypbe NONE -certpbe NONE \
    -passout "pass:${CERT_PASS}" \
    -out "${OUTPUT_DIR}/standalone.p12" \
    -name "Apple Development"

echo "✅ P12 完成"

# ============================================================
# 5. Base64 编码
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
  Apple 高仿证书
============================================
  密码:     ${CERT_PASS}
  有效期:   ~8000年

  文件:
    root_cert.crt      - Apple Root CA 证书
    root_key.key       - Apple Root CA 私钥
    codeca_cert.crt    - 中间 CA 证书
    codeca_key.key     - 中间 CA 私钥
    codeca_csr.csr     - 中间 CA 请求
    dev_cert.crt       - 叶子签名证书
    dev_key.key        - 叶子签名私钥
    dev_csr.csr        - 叶子请求
    chain.crt          - 完整证书链
    fullchain.p12      - 完整 P12（签名用）
    standalone.p12     - 单独身份 P12（设置查看用）
    *.b64              - Base64 编码
============================================
EOF

cd "${OUTPUT_DIR}"
zip -qr "../certificates.zip" .
cd ..

echo "============================================"
echo "  ✅ certificates.zip"
echo "  🔑 密码: ${CERT_PASS}"
echo ""
echo "  📱 查看: standalone.p12"
echo "  ✍️  签名: fullchain.p12"
echo "============================================"
