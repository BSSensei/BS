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
OID_LIST = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 14]
OID_DER = [ObjectIdentifier(f"1.2.840.113635.100.6.1.{i}") for i in OID_LIST]
OID_WWDR      = ObjectIdentifier("1.2.840.113635.100.6.2.1")
OID_DEV_CA    = ObjectIdentifier("1.2.840.113635.100.6.2.6")
OID_CERT_TYPE = ObjectIdentifier("1.2.840.113635.100.6.2.18")
OID_INTEG     = ObjectIdentifier("1.2.840.113635.100.6.3.1")
OID_SEC_BOOT  = ObjectIdentifier("1.2.840.113635.100.6.3.2")
OID_POLICY    = ObjectIdentifier("1.2.840.113635.100.5.1")

# ============================================================
# Cert Type 扩展的值：OCTET STRING 包含 UTF8String
# 真实证书结构: OCTET STRING { UTF8String "Apple Development" }
# DER: 04 13 0C 11 41 70 70 6C 65 20 44 65 76 65 6C 6F 70 6D 65 6E 74
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
