#!/usr/bin/env python3
"""Create a LAN-only authenticated coturn user service; never print its secret."""
import argparse
import ipaddress
import os
from pathlib import Path
import secrets
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--listen', required=True)
parser.add_argument('--peer', action='append', default=[])
parser.add_argument('--prefix', type=Path, default=Path.home() / '.local/share/parlora-turn')
args = parser.parse_args()
listen = str(ipaddress.IPv4Address(args.listen))
peers = sorted({listen, *(str(ipaddress.IPv4Address(p)) for p in args.peer)})
prefix = args.prefix.resolve()
if not (prefix / 'bin/turnserver').is_file():
    raise SystemExit('Run install.sh first')
os.umask(0o077)
(prefix / 'etc').mkdir(exist_ok=True)
secret_file = prefix / 'etc/auth-secret'
if not secret_file.exists():
    secret_file.write_text(secrets.token_hex(32) + '\n')
secret_file.chmod(0o600)
secret = secret_file.read_text().strip()
if len(secret) != 64 or any(c not in '0123456789abcdef' for c in secret):
    raise SystemExit('Unexpected existing secret format')
config = f'''listening-ip={listen}
relay-ip={listen}
listening-port=3478
min-port=49160
max-port=49191
realm=parlora-test
fingerprint
use-auth-secret
static-auth-secret={secret}
no-tls
no-tcp-relay
no-multicast-peers
no-auth-pings
no-dynamic-ip-list
no-dynamic-realms
relay-threads=1
user-quota=8
total-quota=16
max-bps=128000
bps-capacity=2048000
max-allocate-timeout=10
log-file=stdout
log-min-level=warning
pidfile={prefix}/turnserver.pid
denied-peer-ip=0.0.0.0-255.255.255.255
denied-peer-ip=::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
'''
config += ''.join(f'allowed-peer-ip={peer}\n' for peer in peers)
config_file = prefix / 'etc/turnserver.conf'
config_file.write_text(config)
config_file.chmod(0o600)
unit_dir = Path.home() / '.config/systemd/user'
unit_dir.mkdir(parents=True, exist_ok=True)
unit = f'''[Unit]
Description=Parlora LAN coturn validation server
[Service]
ExecStart={prefix}/bin/turnserver -c {config_file}
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
UMask=0077
[Install]
WantedBy=default.target
'''
(unit_dir / 'parlora-turn.service').write_text(unit)
subprocess.run(['systemctl', '--user', 'daemon-reload'], check=True)
subprocess.run(['systemctl', '--user', 'enable', '--now', 'parlora-turn.service'], check=True)
subprocess.run(['systemctl', '--user', 'restart', 'parlora-turn.service'], check=True)
print(f'coturn configured on {listen}:3478; UDP relays 49160–49191; authenticated; peer allowlist: {", ".join(peers)}')
