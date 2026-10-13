import contextlib
import hashlib
import io
import json
import struct
import tempfile
import unittest
from pathlib import Path

import apk_signature
from apk_signature import (
    apk_certificates,
    apk_edition,
    certificate_sha256,
    certificate_subject,
    format_fingerprint,
    verify,
)


def der_length(length):
    if length < 0x80:
        return bytes([length])
    body = length.to_bytes((length.bit_length() + 7) // 8, 'big')
    return bytes([0x80 | len(body)]) + body


def der(tag, content):
    return bytes([tag]) + der_length(len(content)) + content


def der_oid(text):
    values = [int(part) for part in text.split('.')]
    body = bytes([values[0] * 40 + values[1]])
    for value in values[2:]:
        chunks = [value & 0x7F]
        value >>= 7
        while value:
            chunks.append(0x80 | (value & 0x7F))
            value >>= 7
        body += bytes(reversed(chunks))
    return der(0x06, body)


def name(common_name):
    attribute = der(0x30, der_oid('2.5.4.3') + der(0x0C, common_name.encode('utf-8')))
    return der(0x30, der(0x31, attribute))


def certificate(subject_common_name, issuer_common_name='guoapp'):
    algorithm = der(0x30, der_oid('1.2.840.113549.1.1.11') + der(0x05, b''))
    tbs = der(0xA0, der(0x02, b'\x02')) + der(0x02, b'\x01') + algorithm
    tbs += name(issuer_common_name)
    tbs += der(0x30, der(0x17, b'260101000000Z') + der(0x17, b'500101000000Z'))
    tbs += name(subject_common_name)
    return der(0x30, der(0x30, tbs) + algorithm + der(0x03, b'\x00\x00'))


def length_prefixed(data):
    return struct.pack('<I', len(data)) + data


def v2_value(certificates):
    encoded = b''.join(length_prefixed(item) for item in certificates)
    signed_data = length_prefixed(b'') + length_prefixed(encoded) + length_prefixed(b'')
    signer = length_prefixed(signed_data) + length_prefixed(b'') + length_prefixed(b'\x01')
    return length_prefixed(length_prefixed(signer))


def apk_bytes(certificates, signing=True):
    body = b'PK\x03\x04' + b'payload'
    block = b''
    if signing:
        entry = struct.pack('<I', 0x7109871A) + v2_value(certificates)
        pairs = struct.pack('<Q', len(entry)) + entry
        size = len(pairs) + 24
        block = struct.pack('<Q', size) + pairs + struct.pack('<Q', size) + b'APK Sig Block 42'
    directory = b'PK\x01\x02' + b'directory'
    central_offset = len(body) + len(block)
    eocd = b'PK\x05\x06' + struct.pack('<HHHHIIH', 0, 0, 1, 1, len(directory), central_offset, 0)
    return body + block + directory + eocd


class ApkSignatureTests(unittest.TestCase):
    def write(self, directory, name, certificates, signing=True):
        path = Path(directory) / name
        path.write_bytes(apk_bytes(certificates, signing))
        return path

    def fingerprints(self, directory, values):
        path = Path(directory) / 'fingerprints.json'
        path.write_text(json.dumps(values), encoding='utf-8')
        return path

    def run_verify(self, paths, fingerprints):
        with contextlib.redirect_stdout(io.StringIO()):
            return verify(paths, fingerprints)

    def test_v2_signing_block_yields_certificate_and_subject(self):
        with tempfile.TemporaryDirectory() as temporary:
            certificate_der = certificate('hongguojian')
            apk = self.write(temporary, 'hongguojian-0.2.156-arm64-v8a.apk', [certificate_der])
            extracted = apk_certificates(apk)
        self.assertEqual([scheme for scheme, _ in extracted], ['v2'])
        self.assertEqual(extracted[0][1], certificate_der)
        self.assertEqual(certificate_subject(certificate_der), 'CN=hongguojian')
        self.assertEqual(certificate_sha256(certificate_der),
                         hashlib.sha256(certificate_der).hexdigest())
        self.assertEqual(apk_edition(apk), 'hongguojian')

    def test_artifact_names_map_to_fingerprint_entries(self):
        self.assertEqual(apk_edition(Path('hongguojian-android6-0.2.156-arm64-v8a.apk')), 'android6')
        self.assertEqual(apk_edition(Path('zhenguojian-0.2.156-arm64-v8a.apk')), 'zhenguojian')
        self.assertIsNone(apk_edition(Path('app-release.apk')))

    def test_matching_release_certificate_passes(self):
        with tempfile.TemporaryDirectory() as temporary:
            certificate_der = certificate('hongguojian')
            apk = self.write(temporary, 'hongguojian-0.2.156-arm64-v8a.apk', [certificate_der])
            fingerprints = self.fingerprints(temporary, {'hongguojian': certificate_sha256(certificate_der)})
            self.assertEqual(self.run_verify([apk], fingerprints), 0)

    def test_debug_preview_certificate_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            apk = self.write(temporary, 'hongguojian-0.2.156-arm64-v8a.apk', [certificate('Android Debug')])
            fingerprints = self.fingerprints(
                temporary, {'hongguojian': certificate_sha256(certificate('hongguojian'))})
            self.assertEqual(self.run_verify([apk], fingerprints), 1)

    def test_mismatched_fingerprint_and_unknown_artifact_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            certificate_der = certificate('hongguojian')
            fingerprints = self.fingerprints(
                temporary, {'hongguojian': certificate_sha256(certificate('other'))})
            mismatched = self.write(temporary, 'hongguojian-0.2.156-arm64-v8a.apk', [certificate_der])
            self.assertEqual(self.run_verify([mismatched], fingerprints), 1)
            unknown = self.write(temporary, 'app-release.apk', [certificate_der])
            self.assertEqual(self.run_verify([unknown], fingerprints), 1)

    def test_missing_edition_entry_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            certificate_der = certificate('zhenguojian')
            apk = self.write(temporary, 'zhenguojian-0.2.156-arm64-v8a.apk', [certificate_der])
            fingerprints = self.fingerprints(temporary, {})
            self.assertEqual(self.run_verify([apk], fingerprints), 1)

    def test_unsigned_or_unparsable_apk_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            fingerprints = self.fingerprints(temporary, {'hongguojian': '0' * 64})
            unsigned = self.write(temporary, 'hongguojian-0.2.156-arm64-v8a.apk', [], signing=False)
            self.assertEqual(self.run_verify([unsigned], fingerprints), 1)
            broken = Path(temporary) / 'zhenguojian-0.2.156-arm64-v8a.apk'
            broken.write_bytes(b'not an apk')
            self.assertEqual(self.run_verify([broken], fingerprints), 1)

    def test_empty_directory_raises(self):
        with tempfile.TemporaryDirectory() as temporary:
            fingerprints = self.fingerprints(Path(temporary), {'hongguojian': '0' * 64})
            with self.assertRaises(ValueError):
                self.run_verify([Path(temporary)], fingerprints)

    def test_invalid_fingerprint_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(ValueError):
                apk_signature.load_fingerprints(self.fingerprints(temporary, {'hongguojian': 'ABC'}))

    def test_repository_fingerprints_cover_published_editions(self):
        expected = apk_signature.load_fingerprints(apk_signature.default_fingerprints)
        self.assertEqual(sorted(expected), ['android6', 'hongguojian', 'zhenguojian'])
        self.assertEqual(expected['android6'], expected['hongguojian'])
        self.assertNotEqual(expected['hongguojian'], expected['zhenguojian'])
        self.assertEqual(format_fingerprint(expected['hongguojian']).count(':'), 31)


if __name__ == '__main__':
    unittest.main()
