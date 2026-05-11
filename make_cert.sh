#!/bin/bash
set -e

TEAM_ID="${1:-0000000000}"
OUTPUT_DIR="${2:-./cert_output}"
CERT_PASS="${3:-1}"

TEAM_ID=$(echo "$TEAM_ID" | xargs)
mkdir -p "$OUTPUT_DIR"
PROJECT_DIR="$(pwd)"

# 使用 Homebrew 安装的 OpenSSL 3
OPENSSL="$(brew --prefix openssl@3)/bin/openssl"
export PATH="$(brew --prefix openssl@3)/bin:$PATH"

echo "============================================"
echo "  Apple 高仿证书生成器"
echo "============================================"

DAYS=2921940

ROOT_SERIAL=$($OPENSSL rand -hex 8 | tr '[:lower:]' '[:upper:]')
CODECA_SERIAL=$($OPENSSL rand -hex 8 | tr '[:lower:]' '[:upper:]')
DEV_SERIAL=$($OPENSSL rand -hex 8 | tr '[:lower:]' '[:upper:]')

# 生成 CA 的 OID 扩展配置文件
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

[ v3_c
