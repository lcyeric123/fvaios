#!/bin/sh
# build_llama.sh - compile llama.cpp required binaries

set -e

apk add --no-cache git cmake build-base

cd /tmp
git clone --depth 1 https://github.com/ggerganov/llama.cpp.git
cd llama.cpp
cmake -B build -DBUILD_SHARED_LIBS=OFF
cmake --build build --target llama-cli llama-server -j$(nproc)

# install binaries as required names
cp build/bin/llama-cli /usr/bin/main
cp build/bin/llama-server /usr/bin/llama-server

cd /
rm -rf /tmp/llama.cpp
apk del git cmake build-base
