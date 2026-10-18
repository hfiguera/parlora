#!/usr/bin/env python3
"""One bounded STUN Binding request; reports numeric success without addresses."""
import argparse
import json
import os
import socket
import struct
import time

parser = argparse.ArgumentParser()
parser.add_argument('server')
parser.add_argument('--port', type=int, default=3478)
args = parser.parse_args()
transaction = os.urandom(12)
cookie = 0x2112A442
request = struct.pack('!HHI', 1, 0, cookie) + transaction
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
    sock.settimeout(3)
    start = time.monotonic()
    sock.sendto(request, (args.server, args.port))
    data, _peer = sock.recvfrom(2048)
    response_type, length, received_cookie = struct.unpack('!HHI', data[:8])
    assert response_type == 0x101 and received_cookie == cookie
    assert data[8:20] == transaction and len(data) == 20 + length
    offset, mapped = 20, False
    while offset < len(data):
        kind, size = struct.unpack('!HH', data[offset:offset + 4])
        value = data[offset + 4:offset + 4 + size]
        if kind == 0x20:
            assert len(value) == 8 and value[1] == 1
            assert struct.unpack('!H', value[2:4])[0] ^ (cookie >> 16)
            mapped = True
        offset += 4 + ((size + 3) // 4) * 4
    assert mapped, 'Missing IPv4 XOR-MAPPED-ADDRESS'
    print(json.dumps({'stun_binding_success': True, 'rtt_ms': round((time.monotonic() - start) * 1000, 2)}))
