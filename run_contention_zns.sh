#!/bin/bash
# ZNS-engine analog of run_contention.sh. Drives the native ZNS tx engine
# (LIB_TYPE=8) through the CobraBench JNI hook instead of ZenFS-backed RocksDB.
#
# Differences from run_contention.sh:
#   - Forces LIB_TYPE=8 and sets ISOLATION_LEVEL / DURABILITY_LEVEL / DRIVE_COUNT.
#   - No `blkzone reset` / `zenfs mkfs`: the ZNS engine resets its own zones on
#     initTx, so every fresh `mvn exec:java` process starts clean.
#   - No RocksDB LD_PRELOAD (librocksdbjni is never loaded here).
#   - Aggregates the ZNS [IO_EVAL] fields (flash_mib_per_sec_pure /
#     user_mib_per_sec_pure), not RocksDB's flash_MiBs / write_amp.
#
# Env overrides:
#   ISO=1        isolation level: 0=SI, 1=SS(StrictSerializability), 2=Causal   (default 1)
#   DRIVES=1     DRIVE_COUNT                                                     (default 1)
#   ITERS=3      iterations per tier                                            (default 3)
#   TXN_NUM=<n>  override the per-bench TXN_NUM_DEFAULT
#   RUN_DIR=...  output dir
#   CKPT=1       ENABLE_NODE_CHECKPOINTING=true (needs even DRIVE_COUNT>=2; note it
#                does NOT actually bound RAM during load). Default 0.
#   WH=<n>       tpcc-threads only: fixed WAREHOUSE_NUM (default 40). Lower it so the
#                dataset fits host RAM (the engine buffers all nodes in RAM).
#
# Usage: ./run_contention_zns.sh {tpcc-threads|rubis-threads|twitter-threads|twitter-skew|tpcc|rubis|twitter}
set -eu
cd "$(dirname "$0")"

BENCH=${1:-}
[[ -z "$BENCH" ]] && { echo "usage: $0 {tpcc|tpcc-threads|rubis|rubis-threads|twitter|twitter-threads|twitter-skew}" >&2; exit 2; }

case "$BENCH" in
  tpcc)            BENCH_TYPE=1; KNOB=WAREHOUSE_NUM;        FIXED_KNOB="THREAD_NUM";                    FIXED_VALUE="40";       LOW=40;    MED=10;   HIGH=1;    TXN_NUM_DEFAULT=4000000 ;;
  tpcc-threads)    BENCH_TYPE=1; KNOB=THREAD_NUM;           FIXED_KNOB="WAREHOUSE_NUM";                 FIXED_VALUE="${WH:-40}"; LOW=40;   MED=80;   HIGH=160;  TXN_NUM_DEFAULT=4000000 ;;
  rubis)           BENCH_TYPE=3; KNOB=RUBIS_USERS_NUM;      FIXED_KNOB="THREAD_NUM";                    FIXED_VALUE="40";       LOW=10000; MED=1000; HIGH=100;  TXN_NUM_DEFAULT=4000000 ;;
  rubis-threads)   BENCH_TYPE=3; KNOB=THREAD_NUM;           FIXED_KNOB="RUBIS_USERS_NUM";               FIXED_VALUE="10000";    LOW=40;    MED=80;   HIGH=160;  TXN_NUM_DEFAULT=4000000 ;;
  twitter)         BENCH_TYPE=4; KNOB=TWITTER_USERS_NUM;    FIXED_KNOB="THREAD_NUM";                    FIXED_VALUE="40";       LOW=10000; MED=1000; HIGH=100;  TXN_NUM_DEFAULT=4000000 ;;
  twitter-threads) BENCH_TYPE=4; KNOB=THREAD_NUM;           FIXED_KNOB="TWITTER_USERS_NUM";             FIXED_VALUE="10000";    LOW=40;    MED=80;   HIGH=160;  TXN_NUM_DEFAULT=4000000 ;;
  twitter-skew)    BENCH_TYPE=4; KNOB=TWITTER_ACTIVATE_SKEW; FIXED_KNOB="THREAD_NUM TWITTER_USERS_NUM"; FIXED_VALUE="40 10000"; LOW=0.1;   MED=0.5;  HIGH=0.99; TXN_NUM_DEFAULT=4000000 ;;
  *) echo "unknown bench: $BENCH" >&2; exit 2 ;;
esac

ISO=${ISO:-1}
DRIVES=${DRIVES:-1}
ITERS=${ITERS:-3}
CKPT=${CKPT:-0}
TXN_NUM=${TXN_NUM:-$TXN_NUM_DEFAULT}
RUN_DIR=${RUN_DIR:-/tmp/cobra/zns_${BENCH}_iso${ISO}_d${DRIVES}_sweep_$(date +%s)}
mkdir -p "$RUN_DIR"

CONFIG_TEMPLATE=config-zns.yaml
CONFIG_ACTIVE=config-zns.zns-${BENCH}.yaml
cp "$CONFIG_TEMPLATE" "$CONFIG_ACTIVE"
sed -i -E "s/^LIB_TYPE: .*/LIB_TYPE: 8/"                  "$CONFIG_ACTIVE"
sed -i -E "s/^ISOLATION_LEVEL: .*/ISOLATION_LEVEL: $ISO/" "$CONFIG_ACTIVE"
sed -i -E "s/^DURABILITY_LEVEL: .*/DURABILITY_LEVEL: 0/"  "$CONFIG_ACTIVE"
sed -i -E "s/^DRIVE_COUNT: .*/DRIVE_COUNT: $DRIVES/"      "$CONFIG_ACTIVE"
sed -i -E "s/^ENABLE_EVAL: .*/ENABLE_EVAL: true/"         "$CONFIG_ACTIVE"
sed -i -E "s/^BENCH_TYPE: .*/BENCH_TYPE: $BENCH_TYPE/"    "$CONFIG_ACTIVE"
if [[ "$CKPT" == "1" ]]; then
  sed -i -E "s/^ENABLE_NODE_CHECKPOINTING: .*/ENABLE_NODE_CHECKPOINTING: true/"  "$CONFIG_ACTIVE"
else
  sed -i -E "s/^ENABLE_NODE_CHECKPOINTING: .*/ENABLE_NODE_CHECKPOINTING: false/" "$CONFIG_ACTIVE"
fi
read -ra _fixed_knobs  <<< "$FIXED_KNOB"
read -ra _fixed_values <<< "$FIXED_VALUE"
for _i in "${!_fixed_knobs[@]}"; do
  sed -i -E "s/^${_fixed_knobs[$_i]}: .*/${_fixed_knobs[$_i]}: ${_fixed_values[$_i]}/" "$CONFIG_ACTIVE"
done
sed -i -E "s/^TXN_NUM: .*/TXN_NUM: $TXN_NUM/"             "$CONFIG_ACTIVE"
sed -i -E 's/^SKIP_LOADING: .*/SKIP_LOADING: false/'      "$CONFIG_ACTIVE"
sed -i -E 's/^SKIP_TESTING: .*/SKIP_TESTING: false/'      "$CONFIG_ACTIVE"

export LD_LIBRARY_PATH=../../jni:${LD_LIBRARY_PATH:-}
export MAVEN_OPTS="-Djava.library.path=../../jni"

run_iter() {
  local tier=$1 value=$2 iter=$3
  local log="$RUN_DIR/${BENCH}_${tier}_${KNOB}${value}_iter${iter}.log"
  sed -i -E "s/^${KNOB}: .*/${KNOB}: $value/" "$CONFIG_ACTIVE"
  echo "=== bench=$BENCH iso=$ISO drives=$DRIVES ckpt=$CKPT tier=$tier $KNOB=$value iter=$iter/$ITERS ==="
  local iter_start=$SECONDS
  # ZNS engine resets its own zones on initTx — no external mkfs needed.
  mvn -q exec:java -Dexec.mainClass=main.Main -Dexec.args="local $CONFIG_ACTIVE" > "$log" 2>&1 || true
  echo "[ITER_RUNTIME] wall_clock_s=$(( SECONDS - iter_start ))" >> "$log"
  echo "-- summary --"
  grep -E "^(#Txn=|Throughput:|total runtime|\[IO_EVAL\]|\[ITER_RUNTIME\])" "$log" | sed 's/^/  /' || true
  echo
}

run_tier() { local tier=$1 value=$2 i; for (( i=1; i<=ITERS; i++ )); do run_iter "$tier" "$value" "$i"; done; }

stats() {
  awk '{ n++; sum+=$1; sq+=$1*$1 }
       END { if (!n) { print "0 0"; exit }
             m=sum/n; v=sq/n - m*m; if (v<0) v=0; printf("%.2f %.2f\n", m, sqrt(v)) }'
}

aggregate_tier() {
  local tier=$1 value=$2
  local files=( "$RUN_DIR"/${BENCH}_${tier}_${KNOB}${value}_iter*.log )
  echo "--- tier=$tier $KNOB=$value over $ITERS iters ---"
  printf "  goodput_tps    = %s\n" "$(grep -h '^Throughput: '  "${files[@]}" | awk '{gsub(",","",$2); print $2}' | stats)"
  printf "  success_pct    = %s\n" "$(grep -h '^#Txn='         "${files[@]}" | grep -oE 'success%=[0-9.]+' | cut -d= -f2 | stats)"
  printf "  flash_MiBs     = %s\n" "$(grep -h '^\[IO_EVAL\]'   "${files[@]}" | grep -oE 'flash_mib_per_sec_pure=[0-9.]+' | cut -d= -f2 | stats)"
  printf "  user_MiBs      = %s\n" "$(grep -h '^\[IO_EVAL\]'   "${files[@]}" | grep -oE 'user_mib_per_sec_pure=[0-9.]+'  | cut -d= -f2 | stats)"
  printf "  test_ms        = %s\n" "$(grep -h '^total runtime: ' "${files[@]}" | awk '{gsub(",","",$3); print $3}' | stats)"
  printf "  iter_wall_s    = %s\n" "$(grep -h '^\[ITER_RUNTIME\]' "${files[@]}" | grep -oE 'wall_clock_s=[0-9.]+' | cut -d= -f2 | stats)"
  echo
}

mvn -q package -DskipTests >/dev/null

run_tier low    "$LOW"
run_tier medium "$MED"
run_tier high   "$HIGH"

echo "================ Aggregate (zns $BENCH iso=$ISO drives=$DRIVES) ================"
aggregate_tier low    "$LOW"
aggregate_tier medium "$MED"
aggregate_tier high   "$HIGH"
echo "Logs: $RUN_DIR"
