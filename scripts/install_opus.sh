#!/bin/sh
# Build the selected system codec into an explicit prefix (also used by CI).
set -eu
: "${1:?Usage: scripts/install_opus.sh /absolute/install/prefix}"
case "$1" in /*) ;; *) echo 'An absolute prefix is required' >&2; exit 1;; esac
parlora_opus_prefix=$1
parlora_opus_build=$(mktemp -d)
trap 'rm -rf "$parlora_opus_build"' EXIT HUP INT TERM
curl --fail --location --silent --show-error \
  https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz \
  -o "$parlora_opus_build/opus.tar.gz"
python3 - "$parlora_opus_build/opus.tar.gz" <<'PY'
import hashlib, pathlib, sys
expected = '6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1'
if hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest() != expected:
    raise SystemExit('libopus source checksum mismatch')
PY
tar -xzf "$parlora_opus_build/opus.tar.gz" -C "$parlora_opus_build"
cd "$parlora_opus_build/opus-1.6.1"
./configure --prefix="$parlora_opus_prefix" --disable-doc --disable-extra-programs
make -j2
make install
