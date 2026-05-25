#!/bin/bash

# Exit on error
set -e

# Rebuild Java components
echo "Building CobraBench..."
mvn clean package -DskipTests

export LD_LIBRARY_PATH=../../jni:$LD_LIBRARY_PATH

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
