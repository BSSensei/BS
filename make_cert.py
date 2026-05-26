#!/usr/bin/env python3
"""Apple 高仿证书生成器 - 系统文件 OID 版"""
import datetime, os, sys, base64, zipfile, uuid, random, string
from cryptography import x509
from cryptography.x509.oid import ObjectIdentifier, NameOID, ExtendedKeyUsageOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.serialization import pkcs12

TEAM_ID = sys.argv[1] if len(sys.argv) > 1 else "59GAB85EFG"
OUTPUT_DIR = sys.argv[2] if len(sys.argv) > 2 else "./cert_output"
CERT_PASS = "1"
DAYS = 2912000

os.makedirs(OUTPUT_DIR, exist_ok=True)

# ============================================================
# OID（来源：Anchors.plist + CertPinning.plist）
# ============================================================
# CA 证书策略
OID_ROOT_GENERIC  = ObjectIdentifier("1.2.840.113635.100.1.2")
OID_ROOT_CODESIGN = ObjectIdentifier("1.2.840.113635.100.1.108")

# 叶子证书策略
OID_POLICY_5_1      = ObjectIdentifier("1.2.840.113635.100.5.1")
OID_APPLE_ISSUED_1  = ObjectIdentifier("1.2.840.113635.100.6.86")
OID_APPLE_ISSUED_2  = ObjectIdentifier("1.2.840.113635.100.6.87")

# 代码签名平台（6.1.1 - 6.1.10）
OID_1_x = [ObjectIdentifier(f"1.2.840.113635.100.6.1.{i}") for i in range(1, 11)]

# IPA 签名核心（来自 Anchors.plist）
OID_IPA_SIGNING = ObjectIdentifier("1.2.840.113635.100.6.1.13")

# WWDR 标记
OID_WWDR = ObjectIdentifier("1.2.840.113635.100.6.2.1")

# 系统安全
OID_INTEG    = ObjectIdentifier("1.2.840.113635.100.6.3.1")
OID_SEC_BOOT = ObjectIdentifier("1.2.840.113635.100.6.3.2")

# CertPinning 标记
OID_PROD_MARK = ObjectIdentifier("1.2.840.113635.100.6.27.11.1")
OID_LEAF_MARK = ObjectIdentifier("1.2.840.113635.100.6.27.18")

def gen_key():
    return rsa.generate_private_key(65537, 2048, default_backend())

def build_cert(subject, issuer, issuer_key, subject_key, is_ca=False):
    pub = subject_key.public_key()
    builder = x509.CertificateBuilder()
    builder = builder.subject_name(subject)
    builder = builder.issuer_name(issuer)
    builder = builder.serial_number(x509.random_serial_number())
    builder = builder.not_valid_before(datetime.datetime.now(datetime.timezone.utc))
    builder = builder.not_valid_after(
        datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=DAYS))
    builder = builder.public_key(pub)

    builder = builder.add_extension(
        x509.BasicConstraints(ca=is_ca, path_length=None), critical=True)
    builder = builder.add_extension(
        x509.SubjectKeyIdentifier.from_public_key(pub), critical=False)
    builder = builder.add_extension(
        x509.AuthorityKeyIdentifier.from_issuer_public_key(
            issuer_key.public_key()), critical=False)

    if is_ca:
        builder = builder.add_extension(
            x509.KeyUsage(digital_signature=True, key_cert_sign=True,
                          crl_sign=True, content_commitment=False,
                          key_encipherment=False, data_encipherment=False,
                          key_agreement=False, encipher_only=False,
                          decipher_only=False), critical=True)
        # CA 策略：根策略
        builder = builder.add_extension(
            x509.CertificatePolicies([
                x509.PolicyInformation(OID_ROOT_GENERIC, policy_qualifiers=None),
                x509.PolicyInformation(OID_ROOT_CODESIGN, policy_qualifiers=None),
            ]), critical=False)
    else:
        builder = builder.add_extension(
            x509.KeyUsage(digital_signature=True, content_commitment=False,
                          key_encipherment=False, data_encipherment=False,
                          key_agreement=False, key_cert_sign=False,
                          crl_sign=False, encipher_only=False,
                          decipher_only=False), critical=True)
        builder = builder.add_extension(
            x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CODE_SIGNING]), critical=False)
        # 叶子策略
        builder = builder.add_extension(
            x509.CertificatePolicies([
                x509.PolicyInformation(OID_POLICY_5_1, policy_qualifiers=[
                    "https://www.apple.com/certificateauthority/"]),
                x509.PolicyInformation(OID_APPLE_ISSUED_1, policy_qualifiers=None),
                x509.PolicyInformation(OID_APPLE_ISSUED_2, policy_qualifiers=None),
            ]), critical=False)

    builder = builder.add_extension(
        x509.CRLDistributionPoints([
            x509.DistributionPoint(
                full_name=[x509.UniformResourceIdentifier(
                    "http://crl.apple.com/root.crl")],
                relative_name=None, reasons=None, crl_issuer=None
            )
        ]), critical=False)
    builder = builder.add_extension(
        x509.AuthorityInformationAccess([
            x509.AccessDescription(
                x509.oid.AuthorityInformationAccessOID.OCSP,
                x509.UniformResourceIdentifier("http://ocsp.apple.com/ocsp03-wwdr01")
            )
        ]), critical=False)
    builder = builder.add_extension(
        x509.SubjectAlternativeName([
            x509.RFC822Name("apple@apple.com")
        ]), critical=False)

    if not is_ca:
        for oid in OID_1_x:
            builder = builder.add_extension(
                x509.UnrecognizedExtension(oid, b'\x05\x00'), critical=False)
        builder = builder.add_extension(
            x509.UnrecognizedExtension(OID_IPA_SIGNING, TEAM_ID.encode()), critical=False)
        builder = builder.add_extension(
            x509.UnrecognizedExtension(OID_WWDR, b'\x05\x00'), critical=False)
        builder = builder.add_extension(
            x509.UnrecognizedExtension(OID_INTEG, b'\x05\x00'), critical=False)
        builder = builder.add_extension(
            x509.UnrecognizedExtension(OID_SEC_BOOT, b'\x05\x00'), critical=False)
        builder = builder.add_extension(
            x509.UnrecognizedExtension(OID_PROD_MARK, b'\x05\x00'), critical=False)
        builder = builder.add_extension(
            x509.UnrecognizedExtension(OID_LEAF_MARK, b'\x05\x00'), critical=False)

    return builder.sign(issuer_key, hashes.SHA256(), default_backend())

def write_key(path, key):
    with open(path, "wb") as f:
        f.write(key.private_bytes(serialization.Encoding.PEM,
                 serialization.PrivateFormat.TraditionalOpenSSL,
                 serialization.NoEncryption()))

def write_cert(path, cert):
    with open(path, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))

# ============================================================
print(">>> Root CA...")
root_key = gen_key()
root_subj = x509.Name([
    x509.NameAttribute(NameOID.COUNTRY_NAME, "US"),
    x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Apple Inc."),
    x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, "Apple Certification Authority"),
    x509.NameAttribute(NameOID.COMMON_NAME, "Apple Root CA"),
])
root_cert = build_cert(root_subj, root_subj, root_key, root_key, is_ca=True)
write_key(f"{OUTPUT_DIR}/root_key.key", root_key)
write_cert(f"{OUTPUT_DIR}/root_cert.crt", root_cert)
print("✅ Root CA")

print(">>> 中间 CA...")
codeca_key = gen_key()
codeca_subj = x509.Name([
    x509.NameAttribute(NameOID.COUNTRY_NAME, "US"),
    x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Apple Inc."),
    x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, "Apple Certification Authority"),
    x509.NameAttribute(NameOID.COMMON_NAME, "Apple iPhone Certification Authority"),
])
codeca_cert = build_cert(codeca_subj, root_subj, root_key, codeca_key, is_ca=True)
write_key(f"{OUTPUT_DIR}/codeca_key.key", codeca_key)
write_cert(f"{OUTPUT_DIR}/codeca_cert.crt", codeca_cert)
print("✅ 中间 CA")

print(">>> 签名证书...")
dev_key = gen_key()
dev_subj = x509.Name([
    x509.NameAttribute(NameOID.COUNTRY_NAME, "US"),
    x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Apple Inc."),
    x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, TEAM_ID),
    x509.NameAttribute(NameOID.COMMON_NAME, "Apple Development"),
])
dev_cert = build_cert(dev_subj, codeca_subj, codeca_key, dev_key, is_ca=False)
write_key(f"{OUTPUT_DIR}/dev_key.key", dev_key)
write_cert(f"{OUTPUT_DIR}/dev_cert.crt", dev_cert)
print("✅ 签名证书")

# ============================================================
print(">>> P12...")
p12_full = pkcs12.serialize_key_and_certificates(
    b"Apple Development", dev_key, dev_cert, [codeca_cert, root_cert],
    serialization.BestAvailableEncryption(CERT_PASS.encode()))
with open(f"{OUTPUT_DIR}/fullchain.p12", "wb") as f: f.write(p12_full)
print("✅ P12")

# ============================================================
print(">>> 证书链 TXT...")
def cert_text(cert, title):
    pub = cert.public_key().public_bytes(
        serialization.Encoding.PEM,
        serialization.PublicFormat.SubjectPublicKeyInfo).decode()
    txt = f"""============================================
  {title}
============================================
Subject:      {cert.subject.rfc4514_string()}
Issuer:       {cert.issuer.rfc4514_string()}
Serial:       {cert.serial_number}
Not Before:   {cert.not_valid_before_utc}
Not After:    {cert.not_valid_after_utc}
Fingerprint:  {cert.fingerprint(hashes.SHA256()).hex()}
Public Key:
{pub}
Extensions:
"""
    for ext in cert.extensions:
        txt += f"  {ext.oid._name or ext.oid.dotted_string}: {ext.value}\n"
    return txt

with open(f"{OUTPUT_DIR}/certificate_chain.txt", "w") as f:
    f.write("Apple 高仿证书 — 完整证书链\n\n")
    f.write(cert_text(root_cert, "Apple Root CA"))
    f.write("\n\n")
    f.write(cert_text(codeca_cert, "Apple iPhone Certification Authority"))
    f.write("\n\n")
    f.write(cert_text(dev_cert, "Apple Development"))
print("✅ certificate_chain.txt")

# ============================================================
print(">>> mobileconfig...")
cert_der = dev_cert.public_bytes(serialization.Encoding.DER)
cert_b64 = base64.b64encode(cert_der).decode()
with open(f"{OUTPUT_DIR}/cert.mobileconfig", "w") as f:
    f.write(f'''<?xml version="1.0" encoding="UTF-8"?>
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
</plist>''')
print("✅ mobileconfig")

# ============================================================
print(">>> Base64...")
for f in os.listdir(OUTPUT_DIR):
    if f.endswith(('.crt', '.p12', '.txt', '.mobileconfig')):
        with open(os.path.join(OUTPUT_DIR, f), 'rb') as src:
            b64 = base64.b64encode(src.read()).decode()
            with open(os.path.join(OUTPUT_DIR, f + '.b64'), 'w') as dst:
                dst.write(b64)
print("✅ Base64")

# ============================================================
print(">>> 打包...")
with zipfile.ZipFile("certificates.zip", "w") as zf:
    for f in os.listdir(OUTPUT_DIR):
        zf.write(os.path.join(OUTPUT_DIR, f), f)
print("✅ certificates.zip")
