#!/bin/sh

SDK="$HOME/Downloads/arm-webos-linux-gnueabi_sdk-buildroot"

cmake -S . -B build \
    -DCMAKE_TOOLCHAIN_FILE="$SDK/share/buildroot/toolchainfile.cmake" \
    -DCMAKE_BUILD_TYPE=Release

cmake --build build -j$(nproc)

cd ~/Code/webos-vnc/WebOS-Alpine

rm -r staging
mkdir -p staging
cp build/webos-vnc staging/
cp webos/appinfo.json staging/
cp src/linux-desktop.sh staging/

chmod +x staging/webos-vnc

scp -r staging root@10.4.5.185:/media/developer/apps/usr/palm/applications/com.nscanu.webos-vnc
