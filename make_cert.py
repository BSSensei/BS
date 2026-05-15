#!/usr/bin/env python3
import datetime, os, sys, base64, zipfile, uuid
from cryptography import x509
from cryptography.x509.oid import (
    ObjectIdentifier,
    NameOID,
    ExtendedKeyUsageOID,
    AuthorityInformationAccessOID,
)
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.backends import default_backend
from cryptography.x509.extensions import (
    SubjectKeyIdentifier,
    AuthorityKeyIdentifier,
    CRLDistributionPoints,
    DistributionPoint,
    UniformResourceIdentifier,
    CertificatePolicies,
    PolicyInformation,
    AuthorityInformationAccess,
    AccessDescription,
)
from cryptography.hazmat.primitives.serialization import pkcs12

TEAM_ID = sys.argv[1] if len(sys.argv) > 1 else "0000000000"
OUTPUT_DIR = sys.argv[2] if len(sys.argv) > 2 else "./cert_output"
CERT_PASS = sys.argv[3] if len(sys.argv) > 3 else "1"

os.makedirs(OUTPUT_DIR, exist_ok=True)

# ============================================================
# OID 定义
# ============================================================
OID_LIST = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
OID_DER = [ObjectIdentifier(f"1.2.840.113635.100.6.1.{i}") for i in OID_LIST]
OID_WWDR      = ObjectIdentifier("1.2.840.113635.100.6.2.1")
OID_DEV_CA    = ObjectIdentifier("1.2.840.113635.100.6.2.6")
OID_CERT_TYPE = ObjectIdentifier("1.2.840.113635.100.6.2.18")
OID_INTEG     = ObjectIdentifier("1.2.840.113635.100.6.3.1")
OID_SEC_BOOT  = ObjectIdentifier("1.2.840.113635.100.6.3.2")
OID_POLICY    = ObjectIdentifier("1.2.840.113635.100.5.1")

# ============================================================
# Cert Type 扩展值：OCTET STRING { UTF8String "Apple Development" }
# ============================================================
def build_cert_type_der(type_name="Apple Development"):
    utf8_bytes = type_name.encode("utf-8")
    utf8_der = b'\x0C' + len(utf8_bytes).to_bytes(1, 'big') + utf8_bytes
    octet_der = b'\x04' + len(utf8_der).to_bytes(1, 'big') + utf8_der
    return octet_der

CERT_TYPE_DER = build_cert_type_der("Apple Development")

def gen_key():
    return rsa.generate_private_key(65537, 2048, default_backend())

def make_cert(subject, issuer, issuer_key, subject_key, ca=False, leaf=False):
    builder = x509.CertificateBuilder()
    builder = builder.subject_name(subject)
    builder = builder.issuer_name(issuer)
    serial = x509.random_serial_number()
    serial = abs(serial) & ((1 << 159) - 1)
    builder = builder.serial_number(serial)
    builder = builder.not_valid_before(datetime.datetime.now(datetime.timezone.utc))
    builder = builder.not_valid_after(
        datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=2912000)
    )
    pub_key = subject_key.public_key()
    builder = builder.public_key(pub_key)

    if ca:
        builder = builder.add_extension(
            x509.BasicConstraints(ca=True, path_length=None), critical=True
        )
        builder = builder.add_extension(
            x509.KeyUsage(
                digital_signature=True,
                key_cert_sign=True,
                crl_sign=True,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
    elif leaf:
        builder = builder.add_extension(
            x509.BasicConstraints(ca=False, path_length=None), critical=True
        )
        builder = builder.add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=False,
                crl_sign=False,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        builder = builder.add_extension(
            x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CODE_SIGNING]), critical=False
        )
        builder = builder.add_extension(
            CertificatePolicies([
                PolicyInformation(
                    OID_POLICY,
                    policy_qualifiers=[
                        "https://www.apple.com/certificateauthority/"
                    ],
                )
            ]),
            critical=False,
        )

    # 标准扩展
    builder = builder.add_extension(
        SubjectKeyIdentifier.from_public_key(pub_key), critical=False
    )
    aki = AuthorityKeyIdentifier.from_issuer_public_key(
        issuer_key.public_key()
    )
    builder = builder.add_extension(aki, critical=False)

    crl_dp = CRLDistributionPoints([
        DistributionPoint(
            full_name=[UniformResourceIdentifier("http://crl.apple.com/root.crl")],
            relative_name=None,
            reasons=None,
            crl_issuer=None,
        )
    ])
    builder = builder.add_extension(crl_dp, critical=False)

    if not ca or (ca and subject != issuer):
        aia = AuthorityInformationAccess([
            AccessDescription(
                AuthorityInformationAccessOID.OCSP,
                UniformResourceIdentifier("http://ocsp.apple.com/ocsp03-wwdr01"),
            )
        ])
        builder = builder.add_extension(aia, critical=False)

    # Apple 自定义扩展
    for oid in OID_DER:
        builder = builder.add_extension(
            x509.UnrecognizedExtension(oid, b'\x05\x00'), critical=False
        )

    if leaf:
        builder = builder.add_extension(
            x509.UnrecognizedExtension(OID_WWDR, b'\x05\x00'), critical=False
        )
        builder = builder.add_extension(
            x509.UnrecognizedExtension(OID_DEV_CA, b'\x05\x00'), critical=False
        )
        builder = builder.add_extension(
            x509.UnrecognizedExtension(OID_CERT_TYPE, CERT_TYPE_DER), critical=False
        )
        builder = builder.add_extension(
            x509.UnrecognizedExtension(OID_INTEG, b'\x05\x00'), critical=False
        )
        builder = builder.add_extension(
            x509.UnrecognizedExtension(OID_SEC_BOOT, b'\x05\x00'), critical=False
        )

    return builder.sign(issuer_key, hashes.SHA256(), default_backend())

# ============================================================
print(">>> Root CA...")
root_key = gen_key()
root_subj = x509.Name([
    x509.NameAttribute(NameOID.COUNTRY_NAME, "US"),
    x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Apple Inc."),
    x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, "Apple Certification Authority"),
    x509.NameAttribute(NameOID.COMMON_NAME, "Apple Root CA"),
])
root_cert = make_cert(root_subj, root_subj, root_key, root_key, ca=True)
root_pem = root_cert.public_bytes(serialization.Encoding.PEM)
with open(f"{OUTPUT_DIR}/root_cert.crt", "wb") as f:
    f.write(root_pem)
with open(f"{OUTPUT_DIR}/root_key.key", "wb") as f:
    f.write(root_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption(),
    ))
# 根证书 Base64
root_b64 = base64.b64encode(root_cert.public_bytes(serialization.Encoding.DER)).decode()
with open(f"{OUTPUT_DIR}/root_cert_base64.txt", "w") as f:
    f.write(root_b64)
print("✅ Root CA")

print(">>> 中间 CA...")
codeca_key = gen_key()
codeca_subj = x509.Name([
    x509.NameAttribute(NameOID.COUNTRY_NAME, "US"),
    x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Apple Inc."),
    x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, "Apple Certification Authority"),
    x509.NameAttribute(NameOID.COMMON_NAME, "Apple iPhone Certification Authority"),
])
codeca_cert = make_cert(codeca_subj, root_subj, root_key, codeca_key, ca=True)
codeca_pem = codeca_cert.public_bytes(serialization.Encoding.PEM)
with open(f"{OUTPUT_DIR}/codeca_cert.crt", "wb") as f:
    f.write(codeca_pem)
with open(f"{OUTPUT_DIR}/codeca_key.key", "wb") as f:
    f.write(codeca_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption(),
    ))
print("✅ 中间 CA")

print(">>> 签名证书...")
dev_key = gen_key()
dev_subj = x509.Name([
    x509.NameAttribute(NameOID.COUNTRY_NAME, "US"),
    x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Apple Inc."),
    x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, TEAM_ID),
    x509.NameAttribute(NameOID.COMMON_NAME, "Apple Development"),
])
dev_cert = make_cert(dev_subj, codeca_subj, codeca_key, dev_key, leaf=True)
dev_pem = dev_cert.public_bytes(serialization.Encoding.PEM)
with open(f"{OUTPUT_DIR}/dev_cert.crt", "wb") as f:
    f.write(dev_pem)
with open(f"{OUTPUT_DIR}/dev_key.key", "wb") as f:
    f.write(dev_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption(),
    ))
print("✅ 签名证书")

# ============================================================
print(">>> P12...")
# fullchain.p12 — 完整证书链
p12_full = pkcs12.serialize_key_and_certificates(
    b"Apple Development",
    dev_key,
    dev_cert,
    [codeca_cert, root_cert],
    serialization.BestAvailableEncryption(CERT_PASS.encode()),
)
with open(f"{OUTPUT_DIR}/fullchain.p12", "wb") as f:
    f.write(p12_full)
# fullchain.p12 Base64
p12_full_b64 = base64.b64encode(p12_full).decode()
with open(f"{OUTPUT_DIR}/fullchain_base64.txt", "w") as f:
    f.write(p12_full_b64)

# identity.p12 — 仅身份证书
p12_id = pkcs12.serialize_key_and_certificates(
    b"Apple Development",
    dev_key,
    dev_cert,
    None,
    serialization.BestAvailableEncryption(CERT_PASS.encode()),
)
with open(f"{OUTPUT_DIR}/identity.p12", "wb") as f:
    f.write(p12_id)
# identity.p12 Base64
p12_id_b64 = base64.b64encode(p12_id).decode()
with open(f"{OUTPUT_DIR}/identity_base64.txt", "w") as f:
    f.write(p12_id_b64)
print("✅ P12 + Base64")

# ============================================================
print(">>> mobileconfig...")
cert_der = dev_cert.public_bytes(serialization.Encoding.DER)
cert_b64 = base64.b64encode(cert_der).decode()
mobileconfig = f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadContent</key>
            <data>{cert_b64}</data>
            <key>PayloadDescription</key>
            <string>Apple Development Certificate</string>
            <key>PayloadDisplayName</key>
            <string>Apple Development</string>
            <key>PayloadIdentifier</key>
            <string>com.apple.development.{uuid.uuid4()}</string>
            <key>PayloadType</key>
            <string>com.apple.security.root</string>
            <key>PayloadUUID</key>
            <string>{uuid.uuid4()}</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
    </array>
    <key>PayloadDisplayName</key>
    <string>Apple Development Certificate</string>
    <key>PayloadIdentifier</key>
    <string>com.apple.development.{uuid.uuid4()}</string>
    <key>PayloadRemovalDisallowed</key>
    <false/>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>{uuid.uuid4()}</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>'''
with open(f"{OUTPUT_DIR}/cert.mobileconfig", "w") as f:
    f.write(mobileconfig)
print("✅ mobileconfig")

# ============================================================
# 完整证书链 TXT（包含 PEM 链，可导入系统）
# ============================================================
print(">>> 完整证书链 TXT...")

# PEM 链文本
pem_chain = b""
pem_chain += dev_pem + b"\n"
pem_chain += codeca_pem + b"\n"
pem_chain += root_pem + b"\n"
with open(f"{OUTPUT_DIR}/fullchain.pem", "wb") as f:
    f.write(pem_chain)

def cert_to_detail_text(cert, title):
    lines = []
    lines.append("=" * 60)
    lines.append(f"  {title}")
    lines.append("=" * 60)
    lines.append(f"  Subject      : {cert.subject.rfc4514_string()}")
    lines.append(f"  Issuer       : {cert.issuer.rfc4514_string()}")
    lines.append(f"  Serial       : {cert.serial_number}")
    lines.append(f"  Not Before   : {cert.not_valid_before_utc}")
    lines.append(f"  Not After    : {cert.not_valid_after_utc}")
    lines.append(f"  SHA-1        : {cert.fingerprint(hashes.SHA1()).hex(':')}")
    lines.append(f"  SHA-256      : {cert.fingerprint(hashes.SHA256()).hex(':')}")
    lines.append(f"  Public Key   : {cert.public_key().__class__.__name__}")
    lines.append("-" * 40)
    lines.append("  Extensions:")
    for ext in cert.extensions:
        oid_str = ext.oid.dotted_string
        critical_str = " (critical)" if ext.critical else ""
        val = ext.value
        if hasattr(val, 'public_bytes'):
            val_repr = val.public_bytes().hex()
        else:
            val_repr = str(val)
        if len(val_repr) > 120:
            val_repr = val_repr[:117] + "..."
        lines.append(f"    {oid_str}{critical_str}")
        lines.append(f"      Value: {val_repr}")
    lines.append("=" * 60)
    return "\n".join(lines)

chain_text = []
chain_text.append(cert_to_detail_text(root_cert, "1. Apple Root CA (Self-Signed)"))
chain_text.append("")
chain_text.append(cert_to_detail_text(codeca_cert, "2. Apple iPhone Certification Authority"))
chain_text.append("")
chain_text.append(cert_to_detail_text(dev_cert, "3. Apple Development (Leaf)"))
chain_text.append("")
chain_text.append("=" * 60)
chain_text.append("  Chain Integrity Verification")
chain_text.append("=" * 60)

# 简化签名验证
try:
    codeca_key.public_key().verify(
        dev_cert.signature,
        dev_cert.tbs_certificate_bytes,
        x509.PSS(mgf=x509.MGF1(hashes.SHA256()), salt_length=x509.PSS.DIGEST_LENGTH)
    )
    chain_text.append("  ✅ Intermediate -> Leaf: Signature OK")
except Exception as e:
    chain_text.append(f"  ❌ Intermediate -> Leaf: {e}")

try:
    root_key.public_key().verify(
        codeca_cert.signature,
        codeca_cert.tbs_certificate_bytes,
        x509.PSS(mgf=x509.MGF1(hashes.SHA256()), salt_length=x509.PSS.DIGEST_LENGTH)
    )
    chain_text.append("  ✅ Root -> Intermediate: Signature OK")
except Exception as e:
    chain_text.append(f"  ❌ Root -> Intermediate: {e}")

chain_text.append("=" * 60)
chain_text.append("")
chain_text.append("Certificate Chain (PEM):")
chain_text.append("-" * 40)
chain_text.append(pem_chain.decode())

full_chain_text = "\n".join(chain_text)
with open(f"{OUTPUT_DIR}/certificate_chain.txt", "w") as f:
    f.write(full_chain_text)
print("✅ certificate_chain.txt")

# ============================================================
print(">>> 打包...")
with zipfile.ZipFile("certificates.zip", "w") as zf:
    for f in os.listdir(OUTPUT_DIR):
        zf.write(os.path.join(OUTPUT_DIR, f), f)
print("✅ certificates.zip")
