#!/bin/bash
# Run TPCC across low/medium/high contention tiers and collect summary + IO_EVAL.
# Contention knob: WAREHOUSE_NUM (fixed THREAD_NUM), see the paper's stock-hotspot argument.
set -eu
cd "$(dirname "$0")"

RUN_DIR=${RUN_DIR:-/tmp/cobra/tpcc_sweep_$(date +%s)}
mkdir -p "$RUN_DIR"

CONFIG_TEMPLATE=config-zns.yaml
CONFIG_ACTIVE=config-zns.tpcc.yaml
# start from the ZenFS config, force BENCH_TYPE=1 (TPCC), keep THREAD_NUM/TXN_NUM
cp "$CONFIG_TEMPLATE" "$CONFIG_ACTIVE"
sed -i -E 's/^BENCH_TYPE: .*/BENCH_TYPE: 1/'          "$CONFIG_ACTIVE"
sed -i -E 's/^THREAD_NUM: .*/THREAD_NUM: 40/'         "$CONFIG_ACTIVE"
sed -i -E 's/^TXN_NUM: .*/TXN_NUM: 20000/'            "$CONFIG_ACTIVE"
# We wipe/re-mkfs the ZenFS drive per tier, so each tier must load its own data.
sed -i -E 's/^SKIP_LOADING: .*/SKIP_LOADING: false/'  "$CONFIG_ACTIVE"
sed -i -E 's/^SKIP_TESTING: .*/SKIP_TESTING: false/'  "$CONFIG_ACTIVE"

ITERS=${ITERS:-3}   # override with ITERS=N ./run_tpcc_contention.sh

# One iteration: wipe drive, reload TPCC data, run test, capture summary.
run_iter() {
  local tier=$1
  local warehouses=$2
  local iter=$3
  local log="$RUN_DIR/tpcc_${tier}_w${warehouses}_iter${iter}.log"
  sed -i -E "s/^WAREHOUSE_NUM: .*/WAREHOUSE_NUM: $warehouses/" "$CONFIG_ACTIVE"
  echo "=== tier=$tier warehouses=$warehouses iter=$iter/$ITERS ==="
  # Each iteration starts from a clean ZenFS namespace so aborts + write_amp
  # aren't contaminated by prior LSM state.
  sudo blkzone reset /dev/nvme6n2 || true
  rm -rf /tmp/zenfs_aux/rocksdbtest
  ./../../rocksdb/plugin/zenfs/util/zenfs mkfs \
      --zbd=nvme6n2 --aux_path=/tmp/zenfs_aux/rocksdbtest \
      --finish_threshold=10 --force >/dev/null

  export LD_LIBRARY_PATH=../../jni:${LD_LIBRARY_PATH:-}
  export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/liburing.so.2:/lib/x86_64-linux-gnu/libzbd.so.2:/lib/x86_64-linux-gnu/libgflags.so.2.2
  export MAVEN_OPTS="-Djava.library.path=../../jni"

  mvn -q exec:java -Dexec.mainClass=main.Main -Dexec.args="local $CONFIG_ACTIVE" > "$log" 2>&1 || true

  echo "-- summary --"
  grep -E "^(#Txn=|Throughput:|\[IO_EVAL\])" "$log" | sed 's/^/  /'
  echo
}

run_tier() {
  local tier=$1
  local warehouses=$2
  local i
  for (( i=1; i<=ITERS; i++ )); do
    run_iter "$tier" "$warehouses" "$i"
  done
}

# Print mean/stddev of goodput (txn/sec), success%, and flash_MiBs across a tier's iters.
# stats() takes a stream of numbers on stdin, prints "mean stddev".
stats() {
  awk '{ n++; sum+=$1; sq+=$1*$1 }
       END { if (!n) { print "0 0"; exit }
             m=sum/n; v=sq/n - m*m; if (v<0) v=0; printf("%.2f %.2f\n", m, sqrt(v)) }'
}

aggregate_tier() {
  local tier=$1
  local warehouses=$2
  local files=( "$RUN_DIR"/tpcc_${tier}_w${warehouses}_iter*.log )
  echo "--- tier=$tier warehouses=$warehouses over $ITERS iters ---"

  # Throughput: e.g. "Throughput: 1,519.04 txn/sec (commit txn)"
  local tp
  tp=$(grep -h '^Throughput: ' "${files[@]}" | awk '{gsub(",","",$2); print $2}' | stats)
  printf "  goodput_tps   = %s\n" "$tp"

  # #Txn=... success%=76.15%
  local sc
  sc=$(grep -h '^#Txn=' "${files[@]}" | grep -oE 'success%=[0-9.]+' | cut -d= -f2 | stats)
  printf "  success_pct   = %s\n" "$sc"

  # [IO_EVAL] ... flash_MiBs=NN.NN
  local fm
  fm=$(grep -h '^\[IO_EVAL\]' "${files[@]}" | grep -oE 'flash_MiBs=[0-9.]+' | cut -d= -f2 | stats)
  printf "  flash_MiBs    = %s\n" "$fm"

  # [IO_EVAL] ... write_amp=NN.NNx
  local wa
  wa=$(grep -h '^\[IO_EVAL\]' "${files[@]}" | grep -oE 'write_amp=[0-9.]+' | cut -d= -f2 | stats)
  printf "  write_amp     = %s\n" "$wa"
  echo
}

mvn -q package -DskipTests >/dev/null

run_tier low    40
run_tier medium 10
run_tier high    1

echo "================ Aggregate ================"
aggregate_tier low    40
aggregate_tier medium 10
aggregate_tier high    1

echo "Logs: $RUN_DIR"