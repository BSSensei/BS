#!/bin/bash
set -e

TEAM_ID="${1:-0000000000}"
OUTPUT_DIR="${2:-./cert_output}"
CERT_PASS="${3:-1}"

TEAM_ID=$(echo "$TEAM_ID" | xargs)
mkdir -p "$OUTPUT_DIR"
PROJECT_DIR="$(pwd)"

# 确保使用 brew 安装的 OpenSSL 3
OPENSSL="$(brew --prefix openssl@3)/bin/openssl"
export PATH="$(brew --prefix openssl@3)/bin:$PATH"

echo "============================================"
echo "  Apple 高仿证书生成器"
echo "============================================"

DAYS=2921940

ROOT_SERIAL=$($OPENSSL rand -hex 8 | tr '[:lower:]' '[:upper:]')
CODECA_SERIAL=$($OPENSSL rand -hex 8 | tr '[:lower:]' '[:upper:]')
DEV_SERIAL=$($OPENSSL rand -hex 8 | tr '[:lower:]' '[:upper:]')

# ============================================================
# 生成 OpenSSL 配置文件（CA 和 Leaf 分别使用）
# ============================================================
# CA 配置文件
cat > /tmp/ca_oid.conf << EOF
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
certificatePolicies = 1.3.6.1.4.1.4146.10.3.5
2.18 = DER:05:00
1.3 = DER:05:00
EOF

# 添加 Apple OID 6.1.1-6.1.26 (跳过 1.3 已单独设置)
for i in $(seq 1 26); do
    [ "$i" = "3" ] && continue
    echo "1.${i} = ASN1:NULL" >> /tmp/ca_oid.conf
done

# 6.2.1 - 6.2.22
for i in $(seq 1 22); do
    case $i in
        18|19|20|22) echo "2.${i} = DER:05:00" >> /tmp/ca_oid.conf ;;
        *) echo "2.${i} = ASN1:NULL" >> /tmp/ca_oid.conf ;;
    esac
done

# 6.3.1 - 6.3.5
for i in $(seq 1 5); do
    echo "3.${i} = ASN1:NULL" >> /tmp/ca_oid.conf
done

# 6.5.1
echo "5.1 = ASN1:NULL" >> /tmp/ca_oid.conf

# 叶子证书配置文件
cat > /tmp/leaf_oid.conf << EOF
[ req ]
distinguished_name = req_distinguished_name
req_extensions = v3_leaf
prompt = no

[ req_distinguished_name ]
C = US
O = Apple Inc.
OU = ${TEAM_ID}
CN = Apple iPhone OS Application Signing

[ v3_leaf ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
certificatePolicies = 1.3.6.1.4.1.4146.10.3.5
2.18 = DER:05:00
1.3 = DER:05:00
EOF

for i in $(seq 1 26); do
    [ "$i" = "3" ] && continue
    echo "1.${i} = ASN1:NULL" >> /tmp/leaf_oid.conf
done

for i in $(seq 1 22); do
    case $i in
        18|19|20|22) echo "2.${i} = DER:05:00" >> /tmp/leaf_oid.conf ;;
        *) echo "2.${i} = ASN1:NULL" >> /tmp/leaf_oid.conf ;;
    esac
done

for i in $(seq 1 5); do
    echo "3.${i} = ASN1:NULL" >> /tmp/leaf_oid.conf
done

echo "5.1 = ASN1:NULL" >> /tmp/leaf_oid.conf

# 实际签发时也需要扩展段，我们用 -extensions 指定段名，但还需要指定配置文件，因此保留配置文件。

# ============================================================
# 1. Root CA (自签名)
# ============================================================
echo ">>> [1/5] Root CA..."
$OPENSSL req -x509 -newkey rsa:2048 -nodes \
    -keyout "${OUTPUT_DIR}/root_key.pem" \
    -out "${OUTPUT_DIR}/root_cert.pem" \
    -config /tmp/ca_oid.conf \
    -days ${DAYS} \
    -set_serial "0x${ROOT_SERIAL}" \
    -extensions v3_ca
echo "✅ Root CA"

# ============================================================
# 2. 中间 CA
# ============================================================
echo ">>> [2/5] 中间 CA..."
# 生成 CSR（使用 CA 配置但 CN 不同，需要临时覆盖）
$OPENSSL req -new -newkey rsa:2048 -nodes \
    -keyout "${OUTPUT_DIR}/codeca_key.pem" \
    -out "${OUTPUT_DIR}/codeca_csr.pem" \
    -subj "/C=US/O=Apple Inc./OU=Apple Certification Authority/CN=Apple iPhone Certification Authority" \
    -reqexts v3_ca \
    -config /tmp/ca_oid.conf

# 签发证书
$OPENSSL x509 -req \
    -CAkey "${OUTPUT_DIR}/root_key.pem" \
    -CA "${OUTPUT_DIR}/root_cert.pem" \
    -in "${OUTPUT_DIR}/codeca_csr.pem" \
    -out "${OUTPUT_DIR}/codeca_cert.pem" \
    -days ${DAYS} \
    -set_serial "0x${CODECA_SERIAL}" \
    -extfile /tmp/ca_oid.conf \
    -extensions v3_ca \
    -CAcreateserial
echo "✅ 中间 CA"

# ============================================================
# 3. 签名证书 (Leaf)
# ============================================================
echo ">>> [3/5] 签名证书..."
$OPENSSL req -new -newkey rsa:2048 -nodes \
    -keyout "${OUTPUT_DIR}/dev_key.pem" \
    -out "${OUTPUT_DIR}/dev_csr.pem" \
    -config /tmp/leaf_oid.conf

$OPENSSL x509 -req \
    -CAkey "${OUTPUT_DIR}/codeca_key.pem" \
    -CA "${OUTPUT_DIR}/codeca_cert.pem" \
    -in "${OUTPUT_DIR}/dev_csr.pem" \
    -out "${OUTPUT_DIR}/dev_cert.pem" \
    -days ${DAYS} \
    -set_serial "0x${DEV_SERIAL}" \
    -extfile /tmp/leaf_oid.conf \
    -extensions v3_leaf \
    -CAcreateserial
echo "✅ 签名证书"

# ============================================================
# 4. P12 + Base64
# ============================================================
echo ">>> [4/5] P12 + Base64..."
cat "${OUTPUT_DIR}/codeca_cert.pem" "${OUTPUT_DIR}/root_cert.pem" > "${OUTPUT_DIR}/chain.pem"

$OPENSSL pkcs12 -export \
    -in "${OUTPUT_DIR}/dev_cert.pem" \
    -inkey "${OUTPUT_DIR}/dev_key.pem" \
    -certfile "${OUTPUT_DIR}/chain.pem" \
    -passout "pass:${CERT_PASS}" \
    -out "${OUTPUT_DIR}/certificate.p12" \
    -name "Apple iPhone OS Application Signing"

$OPENSSL base64 -in "${OUTPUT_DIR}/certificate.p12" -out "${OUTPUT_DIR}/certificate.p12.b64"
for f in "${OUTPUT_DIR}"/*.pem; do
    $OPENSSL base64 -in "$f" -out "${f}.b64"
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
  所有 Apple OID 已写入证书
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
