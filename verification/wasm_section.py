#!/usr/bin/env python3
"""Extract one named custom section from a wasm module, or list them.
Usage: wasm_section.py <file> [section-name]"""
import sys, hashlib


def read_leb(buf, i):
    result = 0
    shift = 0
    while True:
        b = buf[i]
        i += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, i
        shift += 7


def sections(data):
    assert data[:8] == b"\x00asm\x01\x00\x00\x00", "not a wasm module"
    i = 8
    while i < len(data):
        sec_id = data[i]
        j = i + 1
        size, j = read_leb(data, j)
        body = data[j : j + size]
        name = ""
        payload = body
        if sec_id == 0:
            nlen, k = read_leb(body, 0)
            name = body[k : k + nlen].decode("utf-8", "replace")
            payload = body[k + nlen :]
        yield sec_id, name, payload
        i = j + size


def main():
    data = open(sys.argv[1], "rb").read()
    want = sys.argv[2] if len(sys.argv) > 2 else None
    for sec_id, name, payload in sections(data):
        if want is None:
            if sec_id == 0:
                print(f"{name}\tsize={len(payload)}\tsha256={hashlib.sha256(payload).hexdigest()[:16]}")
        elif name == want:
            sys.stdout.buffer.write(payload)
            return
    if want is not None:
        sys.exit(f"section {want!r} not found")


if __name__ == "__main__":
    main()
