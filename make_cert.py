#!/usr/bin/env python3
import datetime, os, sys, base64, zipfile
from cryptography import x509
from cryptography.x509.oid import ObjectIdentifier
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.backends import default_backend

TEAM_ID = sys.argv[1] if len(sys.argv) > 1 else "0000000000"
OUTPUT_DIR = sys.argv[2] if len(sys.argv) > 2 else "./cert_output"
CERT_PASS = sys.argv[3] if len(sys.argv) > 3 else "1"

os.makedirs(OUTPUT_DIR, exist_ok=True)

# ============================================================
# OID 定义
# ============================================================
OID_APPLE_EXT = ObjectIdentifier("1.2.840.113635.100.6")

# 6.1.1 - 6.1.10: 系统已知 → DER:0500 (NULL)
# 6.1.11 - 6.1.26: 系统未知 → IA5String (字符串)
OID_MAP_DER  = {i: ObjectIdentifier(f"1.2.840.113635.100.6.1.{i}") for i in range(1, 11)}
OID_MAP_STR  = {i: ObjectIdentifier(f"1.2.840.113635.100.6.1.{i}") for i in range(11, 27)}

OID_WWDR     = ObjectIdentifier("1.2.840.113635.100.6.2.1")
OID_DEV_CA   = ObjectIdentifier("1.2.840.113635.100.6.2.6")
OID_CERT_TYPE= ObjectIdentifier("1.2.840.113635.100.6.2.18")
OID_INTEG    = ObjectIdentifier("1.2.840.113635.100.6.3.1")
OID_SEC_BOOT = ObjectIdentifier("1.2.840.113635.100.6.3.2")
OID_POLICY   = ObjectIdentifier("1.2.840.113635.100.5.1")

def gen_key():
    return rsa.generate_private_key(65537, 2048, default_backend())

def make_cert(subject, issuer, issuer_key, subject_key, ca=False, leaf=False):
    builder = x509.CertificateBuilder()
    builder = builder.subject_name(subject)
    builder = builder.issuer_name(issuer)
    builder = builder.serial_number(x509.random_serial_number())
    builder = builder.not_valid_before(datetime.datetime.now(datetime.timezone.utc))
    builder = builder.not_valid_after(datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=2912000))
    builder = builder.public_key(subject_key.public_key())

    if ca:
        builder = builder.add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        builder = builder.add_extension(x509.KeyUsage(
            digital_signature=True, key_cert_sign=True, crl_sign=True, content_commitment=False,
            key_encipherment=False, data_encipherment=False, key_agreement=False,
            encipher_only=False, decipher_only=False), critical=True)
    elif leaf:
        builder = builder.add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        builder = builder.add_extension(x509.KeyUsage(
            digital_signature=True, content_commitment=False, key_encipherment=False,
            data_encipherment=False, key_agreement=False, key_cert_sign=False, crl_sign=False,
            encipher_only=False, decipher_only=False), critical=True)
        builder = builder.add_extension(x509.ExtendedKeyUsage([x509.oid.ExtendedKeyUsageOID.CODE_SIGNING]), critical=False)
        builder = builder.add_extension(x509.CertificatePolicies([x509.PolicyInformation(OID_POLICY, None)]), critical=False)

    # OID 扩展
    for i in range(1, 11):
        builder = builder.add_extension(x509.UnrecognizedExtension(OID_MAP_DER[i], b'\x05\x00'), critical=False)
    for i in range(11, 27):
        builder = builder.add_extension(x509.UnrecognizedExtension(OID_MAP_STR[i], f"Apple Extension {i}".encode()), critical=False)

    if leaf:
        builder = builder.add_extension(x509.UnrecognizedExtension(OID_WWDR, b'\x05\x00'), critical=False)
        builder = builder.add_extension(x509.UnrecognizedExtension(OID_DEV_CA, b'\x05\x00'), critical=False)
        builder = builder.add_extension(x509.UnrecognizedExtension(OID_CERT_TYPE, b'\x05\x00'), critical=False)
        builder = builder.add_extension(x509.UnrecognizedExtension(OID_INTEG, b'\x05\x00'), critical=False)
        builder = builder.add_extension(x509.UnrecognizedExtension(OID_SEC_BOOT, b'\x05\x00'), critical=False)

    return builder.sign(issuer_key, hashes.SHA256(), default_backend())

# ============================================================
# 生成证书链
# ============================================================
print(">>> Root CA...")
root_key = gen_key()
root_subj = x509.Name([x509.NameAttribute(x509.oid.NameOID.COUNTRY_NAME, "US"),
                       x509.NameAttribute(x509.oid.NameOID.ORGANIZATION_NAME, "Apple Inc."),
                       x509.NameAttribute(x509.oid.NameOID.ORGANIZATIONAL_UNIT_NAME, "Apple Certification Authority"),
                       x509.NameAttribute(x509.oid.NameOID.COMMON_NAME, "Apple Root CA")])
root_cert = make_cert(root_subj, root_subj, root_key, root_key, ca=True)

with open(f"{OUTPUT_DIR}/root_cert.crt", "wb") as f: f.write(root_cert.public_bytes(serialization.Encoding.PEM))
with open(f"{OUTPUT_DIR}/root_key.key", "wb") as f: f.write(root_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption()))
print("✅ Root CA")

print(">>> 中间 CA...")
codeca_key = gen_key()
codeca_subj = x509.Name([x509.NameAttribute(x509.oid.NameOID.COUNTRY_NAME, "US"),
                         x509.NameAttribute(x509.oid.NameOID.ORGANIZATION_NAME, "Apple Inc."),
                         x509.NameAttribute(x509.oid.NameOID.ORGANIZATIONAL_UNIT_NAME, "Apple Certification Authority"),
                         x509.NameAttribute(x509.oid.NameOID.COMMON_NAME, "Apple iPhone Certification Authority")])
codeca_cert = make_cert(codeca_subj, root_subj, root_key, codeca_key, ca=True)

with open(f"{OUTPUT_DIR}/codeca_cert.crt", "wb") as f: f.write(codeca_cert.public_bytes(serialization.Encoding.PEM))
with open(f"{OUTPUT_DIR}/codeca_key.key", "wb") as f: f.write(codeca_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption()))
print("✅ 中间 CA")

print(">>> 签名证书...")
dev_key = gen_key()
dev_subj = x509.Name([x509.NameAttribute(x509.oid.NameOID.COUNTRY_NAME, "US"),
                      x509.NameAttribute(x509.oid.NameOID.ORGANIZATION_NAME, "Apple Inc."),
                      x509.NameAttribute(x509.oid.NameOID.ORGANIZATIONAL_UNIT_NAME, TEAM_ID),
                      x509.NameAttribute(x509.oid.NameOID.COMMON_NAME, "Apple Development")])
dev_cert = make_cert(dev_subj, codeca_subj, codeca_key, dev_key, leaf=True)

with open(f"{OUTPUT_DIR}/dev_cert.crt", "wb") as f: f.write(dev_cert.public_bytes(serialization.Encoding.PEM))
with open(f"{OUTPUT_DIR}/dev_key.key", "wb") as f: f.write(dev_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption()))
print("✅ 签名证书")

# ============================================================
# P12
# ============================================================
print(">>> P12...")
from cryptography.hazmat.primitives.serialization import pkcs12
p12 = pkcs12.serialize_key_and_certificates(b"Apple Development", dev_key, dev_cert, [codeca_cert, root_cert],
    serialization.BestAvailableEncryption(CERT_PASS.encode()) if CERT_PASS else serialization.NoEncryption())
with open(f"{OUTPUT_DIR}/fullchain.p12", "wb") as f: f.write(p12)
print("✅ fullchain.p12")

# ============================================================
# 打包
# ============================================================
print(">>> 打包...")
with zipfile.ZipFile(f"{OUTPUT_DIR}/../certificates.zip", "w") as zf:
    for f in os.listdir(OUTPUT_DIR):
        zf.write(os.path.join(OUTPUT_DIR, f), f)
print(f"✅ certificates.zip")
