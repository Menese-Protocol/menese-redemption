#!/usr/bin/env python3
"""Split a wasm binary into sections; hash each; emit sha256 of the module
with all custom (id=0) sections removed. Usage: wasm_sections.py <file>"""
import sys, hashlib, struct

def read_leb(buf, i):
    result = 0; shift = 0
    while True:
        b = buf[i]; i += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80): return result, i
        shift += 7

def main(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'\x00asm\x01\x00\x00\x00', "not a wasm module"
    i = 8
    stripped = bytearray(data[:8])
    print(f"{path}  total={len(data)}")
    while i < len(data):
        sec_id = data[i]; j = i + 1
        size, j = read_leb(data, j)
        body = data[j:j+size]
        name = ''
        if sec_id == 0:
            nlen, k = read_leb(body, 0)
            name = body[k:k+nlen].decode('utf-8', 'replace')
        h = hashlib.sha256(data[i:j+size]).hexdigest()[:16]
        print(f"  section id={sec_id:2d} {name:38s} size={size:9d} sha256/16={h}")
        if sec_id != 0:
            stripped += data[i:j+size]
        i = j + size
    print(f"  STRIPPED (non-custom only) sha256 = {hashlib.sha256(bytes(stripped)).hexdigest()}")

if __name__ == '__main__':
    main(sys.argv[1])
