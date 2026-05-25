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
from cryptography.hazmat.primitives.serialization import pkcs12

TEAM_ID = sys.argv[1] if len(sys.argv) > 1 else "59GAB85EFG"
OUTPUT_DIR = sys.argv[2] if len(sys.argv) > 2 else "./cert_output"
CERT_PASS = "1"

os.makedirs(OUTPUT_DIR, exist_ok=True)

# ============================================================
OID_CERT_TYPE    = ObjectIdentifier("1.2.840.113635.100.6.2.18")
OID_POLICY       = ObjectIdentifier("1.2.840.113635.100.5.1")
OID_WWDR         = ObjectIdentifier("1.2.840.113635.100.6.2.1")
OID_DEV_CA       = ObjectIdentifier("1.2.840.113635.100.6.2.6")
OID_TEAM_ID      = ObjectIdentifier("1.2.840.113635.100.6.1.13")
OID_CODE_SIGNING = ObjectIdentifier("1.2.840.113635.100.6.1.3")

def gen_key():
    return rsa.generate_private_key(65537, 2048, default_backend())

def add_apple_extensions(builder, pub_key, issuer_key, ca=False, leaf=False):
    # 1. BasicConstraints
    if ca:
        builder = builder.add_extension(
            x509.BasicConstraints(ca=True, path_length=None), critical=True
        )
    else:
        builder = builder.add_extension(
            x509.BasicConstraints(ca=False, path_length=None), critical=True
        )

    # 2. SubjectKeyIdentifier
    builder = builder.add_extension(
        x509.SubjectKeyIdentifier.from_public_key(pub_key), critical=False
    )

    # 3. AuthorityKeyIdentifier
    builder = builder.add_extension(
        x509.AuthorityKeyIdentifier.from_issuer_public_key(issuer_key.public_key()),
        critical=False,
    )

    # 4. KeyUsage
    if ca:
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
    else:
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

    # 5. ExtendedKeyUsage
    if leaf:
        builder = builder.add_extension(
            x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CODE_SIGNING]),
            critical=False,
        )

    # 6. CertificatePolicies
    builder = builder.add_extension(
        x509.CertificatePolicies([
            x509.PolicyInformation(
                OID_POLICY,
                policy_qualifiers=[
                    "https://www.apple.com/certificateauthority/"
                ],
            )
        ]),
        critical=False,
    )

    # 7. CRL Distribution Points
    builder = builder.add_extension(
        x509.CRLDistributionPoints([
            x509.DistributionPoint(
                full_name=[
                    x509.UniformResourceIdentifier("http://crl.apple.com/root.crl")
                ],
                reasons=None,
                crl_issuer=None,
            )
        ]),
        critical=False,
    )

    # 8. Authority Information Access
    builder = builder.add_extension(
        x509.AuthorityInformationAccess([
            x509.AccessDescription(
                AuthorityInformationAccessOID.OCSP,
                x509.UniformResourceIdentifier("http://ocsp.apple.com/ocsp03-wwdr01"),
            )
        ]),
        critical=False,
    )

    # 9. Apple 证书类型标记
    builder = builder.add_extension(
        x509.UnrecognizedExtension(OID_CERT_TYPE, b'\x05\x00'), critical=False
    )

    # 10. 代码签名 OID
    if leaf:
        builder = builder.add_extension(
            x509.UnrecognizedExtension(OID_CODE_SIGNING, b'\x05\x00'), critical=False
        )

    # 11. Team ID 明文
    if leaf:
        builder = builder.add_extension(
            x509.UnrecognizedExtension(OID_TEAM_ID, TEAM_ID.encode()), critical=False
        )

    # 12. WWDR 标记
    if leaf:
        builder = builder.add_extension(
            x509.UnrecognizedExtension(OID_WWDR, b'\x05\x00'), critical=False
        )

    # 13. 开发者 CA 标记
    if leaf:
        builder = builder.add_extension(
            x509.UnrecognizedExtension(OID_DEV_CA, b'\x05\x00'), critical=False
        )

    return builder

def make_cert(subject, issuer, issuer_key, subject_key, ca=False, leaf=False):
    builder = x509.CertificateBuilder()
    builder = builder.subject_name(subject)
    builder = builder.issuer_name(issuer)
    builder = builder.serial_number(x509.random_serial_number())
    builder = builder.not_valid_before(datetime.datetime.now(datetime.timezone.utc))
    builder = builder.not_valid_after(
        datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=2912000)
    )
    pub_key = subject_key.public_key()
    builder = builder.public_key(pub_key)
    builder = add_apple_extensions(builder, pub_key, issuer_key, ca=ca, leaf=leaf)
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
with open(f"{OUTPUT_DIR}/root_cert.crt", "wb") as f:
    f.write(root_cert.public_bytes(serialization.Encoding.PEM))
with open(f"{OUTPUT_DIR}/root_key.key", "wb") as f:
    f.write(root_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption(),
    ))
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
with open(f"{OUTPUT_DIR}/codeca_cert.crt", "wb") as f:
    f.write(codeca_cert.public_bytes(serialization.Encoding.PEM))
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
with open(f"{OUTPUT_DIR}/dev_cert.crt", "wb") as f:
    f.write(dev_cert.public_bytes(serialization.Encoding.PEM))
with open(f"{OUTPUT_DIR}/dev_key.key", "wb") as f:
    f.write(dev_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption(),
    ))
print("✅ 签名证书")

# ============================================================
print(">>> P12...")
p12_full = pkcs12.serialize_key_and_certificates(
    b"Apple Development",
    dev_key,
    dev_cert,
    [codeca_cert, root_cert],
    serialization.BestAvailableEncryption(CERT_PASS.encode()),
)
with open(f"{OUTPUT_DIR}/fullchain.p12", "wb") as f:
    f.write(p12_full)

p12_id = pkcs12.serialize_key_and_certificates(
    b"Apple Development",
    dev_key,
    dev_cert,
    None,
    serialization.BestAvailableEncryption(CERT_PASS.encode()),
)
with open(f"{OUTPUT_DIR}/identity.p12", "wb") as f:
    f.write(p12_id)
print("✅ P12")

# ============================================================
print(">>> 证书链 TXT...")
def cert_to_text(cert, title):
    pubkey = cert.public_key()
    pubkey_pem = pubkey.public_bytes(
        serialization.Encoding.PEM,
        serialization.PublicFormat.SubjectPublicKeyInfo
    ).decode()
    text = f"""============================================
  {title}
============================================
Subject:      {cert.subject.rfc4514_string()}
Issuer:       {cert.issuer.rfc4514_string()}
Serial:       {cert.serial_number}
Not Before:   {cert.not_valid_before_utc}
Not After:    {cert.not_valid_after_utc}
Fingerprint:  {cert.fingerprint(hashes.SHA256()).hex()}
Public Key:
{pubkey_pem}

Extensions:
"""
    for ext in cert.extensions:
        text += f"  {ext.oid._name or ext.oid.dotted_string}: {ext.value}\n"
    return text

with open(f"{OUTPUT_DIR}/certificate_chain.txt", "w") as f:
    f.write("Apple 高仿证书 — 完整证书链\n\n")
    f.write(cert_to_text(root_cert, "Apple Root CA"))
    f.write("\n\n")
    f.write(cert_to_text(codeca_cert, "Apple iPhone Certification Authority"))
    f.write("\n\n")
    f.write(cert_to_text(dev_cert, "Apple Development"))
print("✅ certificate_chain.txt")

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
print(">>> 打包...")
with zipfile.ZipFile("certificates.zip", "w") as zf:
    for f in os.listdir(OUTPUT_DIR):
        zf.write(os.path.join(OUTPUT_DIR, f), f)
print("✅ certificates.zip")
