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
# 生成配置文件
# ============================================================
cat > /tmp/oid_ext.conf << 'EOF'
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, keyCertSign, cRLSign
certificatePolicies = 1.3.6.1.4.1.4146.10.3.5
2.18 = DER:05:00
1.3 = DER:05:00
EOF

for i in $(seq 1 26); do
    [ "$i" = "3" ] && continue
    echo "1.${i} = ASN1:NULL" >> /tmp/oid_ext.conf
done

for i in $(seq 4 26); do
    [ "$i" = "3" ] || echo "1.${i} = ASN1:NULL" >> /tmp/oid_ext.conf
done

for i in $(seq 1 22); do
    case $i in
        18|19|20|22) echo "2.${i} = DER:05:00" >> /tmp/oid_ext.conf ;;
        *) echo "2.${i} = ASN1:NULL" >> /tmp/oid_ext.conf ;;
    esac
done

for i in $(seq 1 5); do
    echo "3.${i} = ASN1:NULL" >> /tmp/oid_ext.conf
done

echo "5.1 = ASN1:NULL" >> /tmp/oid_ext.conf

# 叶子证书配置
cat > /tmp/leaf_ext.conf << 'EOF'
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
certificatePolicies = 1.3.6.1.4.1.4146.10.3.5
2.18 = DER:05:00
1.3 = DER:05:00
EOF

for i in $(seq 1 26); do
    [ "$i" = "3" ] && continue
    echo "1.${i} = ASN1:NULL" >> /tmp/leaf_ext.conf
done

for i in $(seq 1 22); do
    case $i in
        18|19|20|22) echo "2.${i} = DER:05:00" >> /tmp/leaf_ext.conf ;;
        *) echo "2.${i} = ASN1:NULL" >> /tmp/leaf_ext.conf ;;
    esac
done

for i in $(seq 1 5); do
    echo "3.${i} = ASN1:NULL" >> /tmp/leaf_ext.conf
done

echo "5.1 = ASN1:NULL" >> /tmp/leaf_ext.conf

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
    -extfile /tmp/oid_ext.conf
echo "✅ Root CA"

# ============================================================
# 2. 中间 CA
# ============================================================
echo ">>> [2/5] 中间 CA..."
openssl req -new -newkey rsa:2048 -nodes \
    -keyout "${OUTPUT_DIR}/codeca_key.pem" \
    -out "${OUTPUT_DIR}/codeca_csr.pem" \
    -subj "/C=US/O=Apple Inc./OU=Apple Certification Authority/CN=Apple iPhone Certification Authority" \
    -config <(cat /etc/ssl/openssl.cnf /tmp/oid_ext.conf 2>/dev/null || cat /tmp/oid_ext.conf)

openssl x509 -req \
    -CAkey "${OUTPUT_DIR}/root_key.pem" \
    -CA "${OUTPUT_DIR}/root_cert.pem" \
    -in "${OUTPUT_DIR}/codeca_csr.pem" \
    -out "${OUTPUT_DIR}/codeca_cert.pem" \
    -days ${DAYS} \
    -set_serial "0x${CODECA_SERIAL}" \
    -extfile /tmp/oid_ext.conf \
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
    -config <(cat /etc/ssl/openssl.cnf /tmp/leaf_ext.conf 2>/dev/null || cat /tmp/leaf_ext.conf)

openssl x509 -req \
    -CAkey "${OUTPUT_DIR}/codeca_key.pem" \
    -CA "${OUTPUT_DIR}/codeca_cert.pem" \
    -in "${OUTPUT_DIR}/dev_csr.pem" \
    -out "${OUTPUT_DIR}/dev_cert.pem" \
    -days ${DAYS} \
    -set_serial "0x${DEV_SERIAL}" \
    -extfile /tmp/leaf_ext.conf \
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
  所有 OID 已写入证书（含 iOS/tvOS/watchOS/macOS）
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
