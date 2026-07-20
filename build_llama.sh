#!/bin/bash
# build_llama.sh - compile llama.cpp static binaries in chroot

set -e

apk add --no-cache git cmake build-base

cd /tmp
git clone --depth 1 https://github.com/ggerganov/llama.cpp.git
cd llama.cpp
cmake -B build -DLLAMA_STATIC=ON -DBUILD_SHARED_LIBS=OFF
cmake --build build --target main llama-server -j$(nproc)

cp build/bin/main /usr/bin/
cp build/bin/llama-server /usr/bin/

cd /
rm -rf /tmp/llama.cpp
apk del git cmake build-base
