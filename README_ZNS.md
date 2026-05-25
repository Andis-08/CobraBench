# Running TPCC with ZNS Backend on CobraBench

This directory contains the integration of the ZNS Transaction API (`tx_api`) into CobraBench. Follow the steps below to configure and run the TPC-C benchmark using the native ZNS C++ backend.

## Prerequisites

1. **JNI Library Compiled**: Ensure the native library `libzns_tx_jni.so` has been built successfully in the `../../jni` directory.
2. **SPDK/ZNS SSD Initialized**: Ensure your NVMe ZNS device environment is correctly bound via SPDK scripts (e.g., using `setup.sh` or `spdk_zns_init` depending on your environment setups) so that `nativeInitTx` doesn't fail during hardware attach.

## Configuration

We use a dedicated configuration file: `config-zns.yaml`.
Important parameters you might want to tweak before running:

```yaml
# ZNS Backend settings
ISOLATION_LEVEL: 1      # 0 for SnapshotIsolation, 1 for StrictSerializability, 2 for CausalConsistency
DURABILITY_LEVEL: 1     # 0 for DefaultStriping (RAID 0), 1 for SelectiveReplica (RAID 1)
ENABLE_RECOVERY: false  # true or false

# Workload Scaling
TXN_NUM: 1000           # Total number of transactions
WAREHOUSE_NUM: 1        # Number of TPCC warehouses
```
*(Note: `LIB_TYPE: 8` tells CobraBench to inject the `ZnsKv` Java adapter.)*

## How to Run

A wrapper script `run_zns_tpcc.sh` is provided. This script:
1. Configures `MAVEN_OPTS` to properly load the JNI bindings (`-Djava.library.path=../../jni`).
2. Creates any missing logging/latency folders needed by CobraBench (`/tmp/cobra/log`, etc.).
3. Executes the Maven `exec:java` target locally against `config-zns.yaml`.

To execute a test run:

```bash
cd benchmarks/CobraBench
./run_zns_tpcc.sh
```

**Rebuilding CobraBench**:
If you make changes to Java files (`ZnsKv.java`, `Config.java`, etc.), `run_zns_tpcc.sh` does not automatically compile them to save time. To recompile Java first, run:
```bash
mvn clean package -DskipTests
./run_zns_tpcc.sh
```

## Architecture Details

- **JNI Client Proxy**: Located in `src/main/java/site/ycsb/db/ZnsTxClient.java`. Reuses the namespace mapping of `YCSB-Transactions-JNI` to completely avoid re-compiling C++ header definitions.
- **Java Storage Adapter**: Located in `src/main/java/kv_interfaces/ZnsKv.java`. Handles transaction start/commit lifecycle, serializes Strings to byte arrays, and caps read bounds dynamically to protect memory constraints (64KB buffer max limit per lookup).
- **Driver Integration**: Linked implicitly inside `src/main/java/bench/Benchmark.java` and globally defined as Enum flag `ZNS_LIB` mapped to ID `8`.