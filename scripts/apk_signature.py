import argparse
import hashlib
import json
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
default_fingerprints = root / 'android' / 'signing-fingerprints.json'
SIGNING_BLOCK_MAGIC = b'APK Sig Block 42'
EOCD_SIGNATURE = b'PK\x05\x06'
DEBUG_CERTIFICATE_MARKER = b'Android Debug'
SCHEMES = {0x7109871A: 'v2', 0xF05368C0: 'v3'}
EDITIONS = ('hongguojian', 'zhenguojian')
OID_NAMES = {
    '2.5.4.3': 'CN',
    '2.5.4.6': 'C',
    '2.5.4.7': 'L',
    '2.5.4.8': 'ST',
    '2.5.4.10': 'O',
    '2.5.4.11': 'OU',
}


def der_children(data, start, end):
    children = []
    offset = start
    while offset < end:
        if offset + 2 > end:
            raise ValueError('DER 头部越界')
        tag = data[offset]
        length = data[offset + 1]
        header = 2
        if length & 0x80:
            count = length & 0x7F
            if count == 0 or offset + 2 + count > end:
                raise ValueError('不支持的 DER 长度编码')
            length = int.from_bytes(data[offset + 2:offset + 2 + count], 'big')
            header = 2 + count
        content = offset + header
        if content + length > end:
            raise ValueError('DER 长度越界')
        children.append((tag, content, content + length))
        offset = content + length
    return children


def decode_oid(value):
    if not value:
        raise ValueError('DER OID 为空')
    parts = [value[0] // 40, value[0] % 40]
    current = 0
    pending = False
    for byte in value[1:]:
        current = (current << 7) | (byte & 0x7F)
        pending = bool(byte & 0x80)
        if not pending:
            parts.append(current)
            current = 0
    if pending:
        raise ValueError('DER OID 未结束')
    return '.'.join(str(part) for part in parts)


def decode_string(tag, value):
    if tag == 0x1E:
        return value.decode('utf-16-be', 'replace')
    if tag in (0x0C, 0x13, 0x16):
        return value.decode('utf-8', 'replace')
    if tag in (0x14, 0x1A):
        return value.decode('latin-1', 'replace')
    return value.hex()


def certificate_subject(data):
    certificate = der_children(data, 0, len(data))
    if not certificate or certificate[0][0] != 0x30:
        raise ValueError('证书不是 DER SEQUENCE')
    tbs = der_children(data, certificate[0][1], certificate[0][2])[0]
    fields = der_children(data, tbs[1], tbs[2])
    index = 1 if fields and fields[0][0] == 0xA0 else 0
    if len(fields) < index + 5:
        raise ValueError('证书字段不完整')
    subject = fields[index + 4]
    parts = []
    for entry in der_children(data, subject[1], subject[2]):
        for attribute in der_children(data, entry[1], entry[2]):
            attributes = der_children(data, attribute[1], attribute[2])
            if len(attributes) != 2:
                raise ValueError('证书主体字段异常')
            oid = decode_oid(data[attributes[0][1]:attributes[0][2]])
            name = OID_NAMES.get(oid, oid)
            parts.append(name + '=' + decode_string(
                attributes[1][0], data[attributes[1][1]:attributes[1][2]]))
    return ', '.join(parts)


def certificate_sha256(data):
    return hashlib.sha256(data).hexdigest()


def format_fingerprint(digest):
    upper = digest.upper()
    return ':'.join(upper[index:index + 2] for index in range(0, len(upper), 2))


def length_prefixed(data, offset):
    if offset + 4 > len(data):
        raise ValueError('签名块长度前缀缺失')
    length = int.from_bytes(data[offset:offset + 4], 'little')
    start = offset + 4
    if start + length > len(data):
        raise ValueError('签名块长度越界')
    return data[start:start + length], start + length


def locate_signing_block(stream, size):
    if size < 32:
        raise ValueError('文件过小，不是 APK')
    tail_size = min(size, 65557)
    stream.seek(size - tail_size)
    tail = stream.read(tail_size)
    position = tail.rfind(EOCD_SIGNATURE)
    if position < 0 or len(tail) - position < 22:
        raise ValueError('未找到 ZIP 中央目录结束记录')
    central_offset = int.from_bytes(tail[position + 16:position + 20], 'little')
    if central_offset in (0, 0xFFFFFFFF) or central_offset < 32:
        raise ValueError('不支持 ZIP64 或空归档')
    stream.seek(central_offset - 24)
    footer = stream.read(24)
    if footer[8:] != SIGNING_BLOCK_MAGIC:
        raise ValueError('未检测到 APK Signing Block')
    block_size = int.from_bytes(footer[:8], 'little')
    start = central_offset - block_size - 8
    if start < 0:
        raise ValueError('APK Signing Block 长度越界')
    stream.seek(start)
    block = stream.read(central_offset - start)
    if len(block) != block_size + 8:
        raise ValueError('APK Signing Block 不完整')
    return block


def signing_block_pairs(block):
    size = int.from_bytes(block[:8], 'little')
    if int.from_bytes(block[-24:-16], 'little') != size:
        raise ValueError('APK Signing Block 长度不一致')
    pairs = []
    offset = 8
    end = 8 + size - 24
    while offset < end:
        if offset + 12 > end:
            raise ValueError('APK Signing Block 条目越界')
        length = int.from_bytes(block[offset:offset + 8], 'little')
        pair_id = int.from_bytes(block[offset + 8:offset + 12], 'little')
        if length < 4 or offset + 8 + length > end:
            raise ValueError('APK Signing Block 条目长度异常')
        pairs.append((pair_id, block[offset + 12:offset + 8 + length]))
        offset += 8 + length
    return pairs


def signer_certificates(value):
    signers, _ = length_prefixed(value, 0)
    certificates = []
    offset = 0
    while offset < len(signers):
        signer, offset = length_prefixed(signers, offset)
        signed_data, _ = length_prefixed(signer, 0)
        _, after_digests = length_prefixed(signed_data, 0)
        encoded, _ = length_prefixed(signed_data, after_digests)
        inner = 0
        while inner < len(encoded):
            certificate, inner = length_prefixed(encoded, inner)
            certificates.append(certificate)
    return certificates


def apk_certificates(path):
    with path.open('rb') as stream:
        block = locate_signing_block(stream, path.stat().st_size)
    certificates = []
    for pair_id, value in signing_block_pairs(block):
        scheme = SCHEMES.get(pair_id)
        if scheme:
            certificates.extend((scheme, certificate) for certificate in signer_certificates(value))
    return certificates


def apk_edition(path):
    for edition in EDITIONS:
        if path.name.startswith(edition + '-android6-'):
            return 'android6'
        if path.name.startswith(edition + '-'):
            return edition
    return None


def load_fingerprints(path):
    expected = json.loads(Path(path).read_text(encoding='utf-8'))
    for edition, digest in expected.items():
        if not isinstance(digest, str) or len(digest) != 64 or any(
                character not in '0123456789abcdef' for character in digest):
            raise ValueError(str(path) + ' 中的 ' + edition + ' 指纹必须是 64 位小写十六进制。')
    return expected


def collect(paths):
    apks = []
    for path in paths:
        if path.is_dir():
            apks.extend(sorted(path.rglob('*.apk')))
        elif path.is_file():
            apks.append(path)
        else:
            raise ValueError('路径不存在：' + str(path))
    return apks


def verify(paths, fingerprints_path=default_fingerprints):
    expected = load_fingerprints(fingerprints_path)
    apks = collect(paths)
    if not apks:
        raise ValueError('未找到 APK：' + '、'.join(str(path) for path in paths))
    failed = 0
    for apk in apks:
        edition = apk_edition(apk)
        try:
            certificates = apk_certificates(apk)
        except ValueError as error:
            print(apk.name + '：解析失败（' + str(error) + '）')
            failed += 1
            continue
        if not certificates:
            print(apk.name + '：未检测到 v2/v3 签名，无法确认固定签名')
            failed += 1
            continue
        for scheme, certificate in certificates:
            digest = certificate_sha256(certificate)
            problems = []
            if DEBUG_CERTIFICATE_MARKER in certificate:
                problems.append('使用了 Android Debug 预览证书')
            if edition is None:
                problems.append('文件名无法识别版本')
            elif edition not in expected:
                problems.append('signing-fingerprints.json 缺少 ' + edition + ' 指纹')
            elif digest != expected[edition]:
                problems.append('证书指纹不匹配，期望 ' + format_fingerprint(expected[edition]))
            state = '通过' if not problems else '失败'
            print(apk.name + ' ' + scheme + ' ' + state + ' ' + format_fingerprint(digest)
                  + ' ' + certificate_subject(certificate))
            if problems:
                failed += 1
                print('  ' + '；'.join(problems))
    if failed:
        print('签名校验未通过：' + str(failed) + ' 项。')
        return 1
    print('签名校验通过：' + str(len(apks)) + ' 个 APK 使用固定发布证书。')
    return 0


def main():
    parser = argparse.ArgumentParser(description='校验 APK 签名证书指纹，拦截预览签名。')
    parser.add_argument('paths', nargs='*', type=Path, help='APK 文件或目录，默认扫描 dist')
    parser.add_argument('--fingerprints', type=Path, default=default_fingerprints)
    options = parser.parse_args()
    try:
        return verify(options.paths or [Path('dist')], options.fingerprints)
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
