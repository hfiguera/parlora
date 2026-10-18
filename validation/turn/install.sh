#!/bin/sh
# User-local Linux test installation. No system package or firewall changes.
set -eu
[ "$(uname -s)" = Linux ] || { echo 'Run this on Linux' >&2; exit 1; }
parlora_turn_prefix=${1:-"$HOME/.local/share/parlora-turn"}
case "$parlora_turn_prefix" in /*) ;; *) echo 'Use an absolute prefix' >&2; exit 1;; esac
umask 077
mkdir -p "$parlora_turn_prefix/build"
cd "$parlora_turn_prefix/build"
curl -fsSL https://github.com/libevent/libevent/releases/download/release-2.1.12-stable/libevent-2.1.12-stable.tar.gz -o libevent.tar.gz
curl -fsSL https://github.com/coturn/coturn/archive/refs/tags/4.18.0.tar.gz -o coturn.tar.gz
printf '%s\n' '92e6de1be9ec176428fd2367677e61ceffc2ee1cb119035037a27d346b0403bb  libevent.tar.gz' '28d55294ac596fbd129b293a85e7bb1c5dc4bd15b7fb55c500f355149e5f4e28  coturn.tar.gz' | sha256sum -c -
tar -xzf libevent.tar.gz
tar -xzf coturn.tar.gz
(cd libevent-2.1.12-stable && CFLAGS=-fPIC ./configure --prefix="$parlora_turn_prefix" --disable-shared --enable-static --disable-samples --disable-libevent-regress && make -j2 && make install)
(cd coturn-4.18.0 && PKG_CONFIG_PATH="$parlora_turn_prefix/lib/pkgconfig" CPPFLAGS="-I$parlora_turn_prefix/include" LDFLAGS="-L$parlora_turn_prefix/lib" ./configure --prefix="$parlora_turn_prefix" && make -j2 && make install)
"$parlora_turn_prefix/bin/turnserver" --version
