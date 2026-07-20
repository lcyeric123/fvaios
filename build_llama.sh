#!/bin/sh
# build_llama.sh - compile llama.cpp static binaries in chroot

set -e

apk add --no-cache git cmake build-base

cd /tmp
git clone --depth 1 https://github.com/ggerganov/llama.cpp.git
cd llama.cpp
cmake -B build \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_C_FLAGS="-static" \
    -DCMAKE_CXX_FLAGS="-static"
cmake --build build -j$(nproc)

# install required binaries (llama-cli is the former 'main')
cp build/bin/llama-cli /usr/bin/llama-main 2>/dev/null || cp build/bin/main /usr/bin/llama-main
cp build/bin/llama-server /usr/bin/llama-server

cd /
rm -rf /tmp/llama.cpp
apk del git cmake build-base
