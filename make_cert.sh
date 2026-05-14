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
    -addext "1.2.840.113635.100.6.2.18=DER:05:00" \
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
    -addext "1.2.840.113635.100.6.2.18=DER:05:00" \
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

cat > /tmp/leaf.conf << EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_ext
prompt = no

[req_distinguished_name]
C = US
O = Apple Inc.
OU = ${TEAM_ID}
CN = Apple Development

[v3_ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
certificatePolicies = 1.2.840.113635.100.5.1
EOF

for i in $(seq 1 26); do
    echo "1.2.840.113635.100.6.1.${i} = DER:05:00" >> /tmp/leaf.conf
done

cat >> /tmp/leaf.conf << 'EOF'
1.2.840.113635.100.6.2.1 = ASN1:NULL
1.2.840.113635.100.6.2.6 = ASN1:NULL
1.2.840.113635.100.6.2.18 = DER:05:00
1.2.840.113635.100.6.3.1 = ASN1:NULL
1.2.840.113635.100.6.3.2 = ASN1:NULL
EOF

openssl req -new -newkey rsa:2048 -nodes \
    -keyout "${OUTPUT_DIR}/dev_key.key" \
    -out "${OUTPUT_DIR}/dev_csr.csr" \
    -config /tmp/leaf.conf

openssl x509 -req \
    -CAkey "${OUTPUT_DIR}/codeca_key.key" \
    -CA "${OUTPUT_DIR}/codeca_cert.crt" \
    -days 2912000 \
    -in "${OUTPUT_DIR}/dev_csr.csr" \
    -out "${OUTPUT_DIR}/dev_cert.crt" \
    -extfile /tmp/leaf.conf \
    -extensions v3_ext \
    -CAcreateserial
echo "✅ 签名证书"

# ============================================================
# 4. P12 导出
# ============================================================
echo ">>> 导出 P12..."

openssl pkcs12 -export \
    -in "${OUTPUT_DIR}/dev_cert.crt" \
    -inkey "${OUTPUT_DIR}/dev_key.key" \
    -keypbe NONE -certpbe NONE \
    -passout "pass:${CERT_PASS}" \
    -out "${OUTPUT_DIR}/identity.p12" \
    -name "Apple Development"
echo "    → identity.p12"

cat "${OUTPUT_DIR}/codeca_cert.crt" "${OUTPUT_DIR}/root_cert.crt" > "${OUTPUT_DIR}/chain.crt"

openssl pkcs12 -export \
    -in "${OUTPUT_DIR}/dev_cert.crt" \
    -inkey "${OUTPUT_DIR}/dev_key.key" \
    -certfile "${OUTPUT_DIR}/chain.crt" \
    -keypbe NONE -certpbe NONE \
    -passout "pass:${CERT_PASS}" \
    -out "${OUTPUT_DIR}/fullchain.p12" \
    -name "Apple Development"
echo "    → fullchain.p12"

# ============================================================
# 5. CER + mobileconfig
# ============================================================
echo ">>> CER + mobileconfig..."
openssl x509 -in "${OUTPUT_DIR}/dev_cert.crt" -outform DER -out "${OUTPUT_DIR}/dev_cert.cer"
CERT_B64=$(openssl base64 -in "${OUTPUT_DIR}/dev_cert.cer" | tr -d '\n')

cat > "${OUTPUT_DIR}/cert.mobileconfig" << EOFMOBILE
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadContent</key>
            <data>
${CERT_B64}
            </data>
            <key>PayloadDescription</key>
            <string>Apple Development Certificate</string>
            <key>PayloadDisplayName</key>
            <string>Apple Development</string>
            <key>PayloadIdentifier</key>
            <string>com.apple.development.cert</string>
            <key>PayloadType</key>
            <string>com.apple.security.root</string>
            <key>PayloadUUID</key>
            <string>00000000-0000-0000-0000-000000000001</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
    </array>
    <key>PayloadDisplayName</key>
    <string>Apple Development</string>
    <key>PayloadIdentifier</key>
    <string>com.apple.development.profile</string>
    <key>PayloadRemovalDisallowed</key>
    <false/>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>00000000-0000-0000-0000-000000000002</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>
EOFMOBILE
echo "    → cert.mobileconfig"

# ============================================================
# 6. Base64 + TXT + 打包
# ============================================================
echo ">>> 打包..."
for f in "${OUTPUT_DIR}"/*.crt "${OUTPUT_DIR}"/*.key "${OUTPUT_DIR}"/*.csr "${OUTPUT_DIR}"/*.p12 "${OUTPUT_DIR}"/*.cer; do
    [ -f "$f" ] && openssl base64 -in "$f" -out "${f}.b64"
done

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

cat > "${OUTPUT_DIR}/info.txt" << EOF
============================================
  Apple 高仿证书
============================================
  密码:     ${CERT_PASS}
  有效期:   ~8000年

  OID:
    6.1.1-6.1.26  = DER:05:00 (代码签名+内核扩展)
    6.2.1         = ASN1:NULL (WWDR)
    6.2.6         = ASN1:NULL (开发者CA)
    6.2.18        = DER:05:00 (证书类型)
    6.3.1-6.3.2   = ASN1:NULL (系统安全)
    5.1           = 证书策略

  📱 cert.mobileconfig → Safari打开安装
  ✍️  fullchain.p12 → 代码签名
  📋 identity.p12 → 单身份查看
============================================
EOF

cd "${OUTPUT_DIR}"
zip -qr "${PROJECT_DIR}/certificates.zip" .
cd "${PROJECT_DIR}"

echo "============================================"
echo "  ✅ certificates.zip"
echo "  🔑 密码: ${CERT_PASS}"
echo "============================================"
