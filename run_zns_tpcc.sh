#!/bin/bash

# Exit on error
set -e

# Rebuild Java components
echo "Building CobraBench..."
mvn clean package -DskipTests

export LD_LIBRARY_PATH=../../jni:$LD_LIBRARY_PATH

# librocksdbjni-linux64.so (bundled inside rocksdbjni-zenfs jar) was compiled
# with references to io_uring, libzbd, and gflags — but rocksdb's `rocksdbjava`
# Makefile recipe does not propagate PLATFORM_LDFLAGS or plugin pkg-config libs
# to the JNI link line, so DT_NEEDED omits all three. Preload them so their
# symbols resolve when the JVM dlopen's the extracted .so.
export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/liburing.so.2:/lib/x86_64-linux-gnu/libzbd.so.2:/lib/x86_64-linux-gnu/libgflags.so.2.2${LD_PRELOAD:+:$LD_PRELOAD}

echo "Library path set to: $LD_LIBRARY_PATH"

mkdir -p /tmp/cobra/log
mkdir -p /tmp/cobra/latency/

echo "Running TPCC via CobraBench with ZNS_LIB backend..."
# Run the benchmark wrapper using the ZNS_LIB config.
# Ensure that config.yaml or JVM args properly specify ZNS_LIB depending on CobraBench input methods.
# For standard CobraBench setups, editing `config.yaml` is usually required,
# but we can set properties directly to the driver if it supports it.

# Run using MAVEN_OPTS to enforce library path in maven process
export MAVEN_OPTS="-Djava.library.path=../../jni"
mvn exec:java -Dexec.mainClass="main.Main" -Dexec.args="local config-zns.yaml"
