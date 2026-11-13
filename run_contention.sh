#!/bin/bash
# Contention sweep driver — pick a benchmark, run its low/medium/high tiers
# ITERS times each on ZenFS-backed RocksDB, print per-tier aggregates.
#
# Usage:
#   ./run_contention.sh tpcc          # WAREHOUSE_NUM = 40/10/1, THREAD_NUM fixed=40
#                                     # (conflates contention with working-set size:
#                                     #  fewer warehouses = both more contention AND
#                                     #  less data loaded/touched)
#   ./run_contention.sh tpcc-threads  # WAREHOUSE_NUM fixed=40, THREAD_NUM=40/80/160
#                                     # (isolates contention: same data loaded every
#                                     #  tier, since TPCCBench.getNextTxn() picks each
#                                     #  txn's warehouse uniformly at random from
#                                     #  1..WAREHOUSE_NUM with no thread affinity, so
#                                     #  raising THREAD_NUM at fixed WAREHOUSE_NUM
#                                     #  directly raises mean concurrent writers per
#                                     #  warehouse = THREAD_NUM/WAREHOUSE_NUM without
#                                     #  changing how much data gets loaded)
#   ./run_contention.sh rubis          # RUBIS_USERS_NUM = 10000/1000/100, THREAD_NUM fixed=40
#                                      # (same working-set conflation as plain tpcc: shrinking
#                                      #  RUBIS_USERS_NUM shrinks the dataset too, so cache
#                                      #  locality gains can outweigh added lock contention --
#                                      #  observed goodput INCREASE low->medium->high despite
#                                      #  success% correctly dropping 95%->91%->81% in one run)
#   ./run_contention.sh rubis-threads  # RUBIS_USERS_NUM fixed=10000, THREAD_NUM=40/80/160
#                                      # (isolates contention; RubisBench.getNextTxn() also
#                                      #  draws ids per-txn with no thread affinity)
#   ./run_contention.sh twitter         # TWITTER_USERS_NUM = 10000/1000/100, THREAD_NUM fixed=40
#                                      # (same conflation as rubis/tpcc; TwitterBench.getNextTxn()
#                                      #  draws a Zipfian userId per-txn, no thread affinity)
#   ./run_contention.sh twitter-threads # TWITTER_USERS_NUM fixed=10000, THREAD_NUM=40/80/160
#   ./run_contention.sh twitter-skew    # TWITTER_USERS_NUM fixed=10000, THREAD_NUM fixed=40,
#                                       # TWITTER_ACTIVATE_SKEW=0.1/0.5/0.99
#                                       # (cleanest isolation: dataset size AND thread count
#                                       #  both held constant; only the Zipfian skew on
#                                       #  activateUserZipf changes how concentrated access
#                                       #  is on a hot set of users -- see
#                                       #  TwitterBench.java:20 / Config.TWITTER_ACTIVATE_SKEW)
#
# Overridable via env:
#   ITERS=5 ./run_contention.sh tpcc
#   RUN_DIR=/tmp/foo ./run_contention.sh rubis
#   TXN_NUM=4000000 ./run_contention.sh rubis-threads
#   WH=10 ./run_contention.sh tpcc-threads   # fixed WAREHOUSE_NUM (default 40), as in
#                                            # run_contention_zns.sh, so both engines can be
#                                            # run on the same data set
set -eu
cd "$(dirname "$0")"

BENCH=${1:-}
[[ -z "$BENCH" ]] && { echo "usage: $0 {tpcc|tpcc-threads|rubis|rubis-threads|twitter|twitter-threads|twitter-skew}" >&2; exit 2; }

# TXN_NUM_DEFAULT is sized so the FASTEST tier of each bench (highest
# attempted tx/s) still takes >=60s of test-phase wall time; slower tiers
# then simply run longer than 60s. Basis:
#   tpcc:    measured ~9985 attempted tx/s (low/medium tier) -> 9985*60*1.25 ~= 748,875 -> 750,000
#            (high tier ~4996 tx/s attempted -> ~150s test phase; slower but still >=60s)
#   rubis:   measured low tier (RUBIS_USERS_NUM=10000) at TXN_NUM=200000: ~99,854
#            attempted tx/s, consistent across 3 iters (200000 finished in ~2.0s
#            every time -- the earlier "~1995 tx/s" estimate was a JIT/cold-start
#            artifact from a too-short 2000-txn probe, not the real steady-state
#            rate). Per the tpcc low-vs-medium pattern (medium ran ~40% faster
#            than low due to smaller working set / better cache locality), assume
#            medium here could hit ~140k tx/s -> 150,000*60*1.3 ~= 11,700,000 ->
#            12,000,000.
#   twitter: no data at all; reused rubis's corrected estimate as a starting
#            guess (same code shape, likely similar order of magnitude).
# After the first real sweep, grep "total runtime" in each tier's iter1 log;
# if any tier undershoots 60,000 ms, bump that bench's value below and rerun
# just that bench. Override ad-hoc via `TXN_NUM=<n> ./run_contention.sh ...`.
# FIXED_KNOB/FIXED_VALUE hold everything except KNOB constant across all
# tiers. Both may be a SPACE-SEPARATED LIST of equal length (e.g. two knobs
# fixed at once) -- applied via a paired loop below, not a single sed.
# KNOB/LOW/MED/HIGH is what actually varies tier to tier.
case "$BENCH" in
  tpcc)         BENCH_TYPE=1; KNOB=WAREHOUSE_NUM;        FIXED_KNOB="THREAD_NUM";                    FIXED_VALUE="40";       LOW=40;    MED=10;   HIGH=1;    TXN_NUM_DEFAULT=750000 ;;
  tpcc-threads) BENCH_TYPE=1; KNOB=THREAD_NUM;           FIXED_KNOB="WAREHOUSE_NUM";                 FIXED_VALUE="${WH:-40}"; LOW=40;   MED=80;   HIGH=160;  TXN_NUM_DEFAULT=750000 ;;
  rubis)          BENCH_TYPE=3; KNOB=RUBIS_USERS_NUM;      FIXED_KNOB="THREAD_NUM";                    FIXED_VALUE="40";       LOW=10000; MED=1000; HIGH=100;  TXN_NUM_DEFAULT=12000000 ;;
  rubis-threads)  BENCH_TYPE=3; KNOB=THREAD_NUM;           FIXED_KNOB="RUBIS_USERS_NUM";                FIXED_VALUE="10000";    LOW=40;    MED=80;   HIGH=160;  TXN_NUM_DEFAULT=12000000 ;;
  twitter)        BENCH_TYPE=4; KNOB=TWITTER_USERS_NUM;    FIXED_KNOB="THREAD_NUM";                    FIXED_VALUE="40";       LOW=10000; MED=1000; HIGH=100;  TXN_NUM_DEFAULT=12000000 ;;
  twitter-threads) BENCH_TYPE=4; KNOB=THREAD_NUM;          FIXED_KNOB="TWITTER_USERS_NUM";              FIXED_VALUE="10000";    LOW=40;    MED=80;   HIGH=160;  TXN_NUM_DEFAULT=12000000 ;;
  # twitter-skew sizing: measured low (skew=0.1) at 46,133 attempted tx/s
  # (12,000,000/260.1s, consistent across 2 completed iters); medium
  # (skew=0.5) at 65,895 tx/s (from the equivalent-config twitter/low run);
  # high (skew=0.99) unmeasured but likely faster still (more concentration
  # -> better cache locality, same pattern seen elsewhere). Sized off a
  # ~100,000 tx/s ceiling estimate for high: 100,000*60*1.2 ~= 7,200,000 ->
  # 7,000,000 (down from the original 12,000,000, which overshot the low
  # tier's 60s floor by ~4x at 260s/iter).
  twitter-skew)    BENCH_TYPE=4; KNOB=TWITTER_ACTIVATE_SKEW; FIXED_KNOB="THREAD_NUM TWITTER_USERS_NUM"; FIXED_VALUE="40 10000"; LOW=0.1;   MED=0.5;  HIGH=0.99; TXN_NUM_DEFAULT=7000000 ;;
  *) echo "unknown bench: $BENCH" >&2; exit 2 ;;
esac

ITERS=${ITERS:-3}
# The RocksDB backend (RocksDBKV and the locally installed rocksdbjni-zenfs jar) is only in
# the build under the `rocksdb` Maven profile; the default build leaves it out, and then
# LIB_TYPE=2 fails at startup (README_ZNS.md, "The RocksDB backend is optional"). Every run
# here is RocksDB, so both the build and exec:java -- whose classpath needs the jar -- use it.
MVN_PROFILE=rocksdb
TXN_NUM=${TXN_NUM:-$TXN_NUM_DEFAULT}
RUN_DIR=${RUN_DIR:-/tmp/cobra/${BENCH}_sweep_$(date +%s)}
mkdir -p "$RUN_DIR"

CONFIG_TEMPLATE=config-zns.yaml
CONFIG_ACTIVE=config-zns.${BENCH}.yaml
cp "$CONFIG_TEMPLATE" "$CONFIG_ACTIVE"
sed -i -E "s/^BENCH_TYPE: .*/BENCH_TYPE: $BENCH_TYPE/"     "$CONFIG_ACTIVE"
read -ra _fixed_knobs  <<< "$FIXED_KNOB"
read -ra _fixed_values <<< "$FIXED_VALUE"
for _i in "${!_fixed_knobs[@]}"; do
  sed -i -E "s/^${_fixed_knobs[$_i]}: .*/${_fixed_knobs[$_i]}: ${_fixed_values[$_i]}/" "$CONFIG_ACTIVE"
done
sed -i -E "s/^TXN_NUM: .*/TXN_NUM: $TXN_NUM/"              "$CONFIG_ACTIVE"
# Wipe/re-mkfs per iter → each iter loads its own data.
sed -i -E 's/^SKIP_LOADING: .*/SKIP_LOADING: false/'      "$CONFIG_ACTIVE"
sed -i -E 's/^SKIP_TESTING: .*/SKIP_TESTING: false/'      "$CONFIG_ACTIVE"

run_iter() {
  local tier=$1
  local value=$2
  local iter=$3
  local log="$RUN_DIR/${BENCH}_${tier}_${KNOB}${value}_iter${iter}.log"
  sed -i -E "s/^${KNOB}: .*/${KNOB}: $value/" "$CONFIG_ACTIVE"
  echo "=== bench=$BENCH tier=$tier $KNOB=$value iter=$iter/$ITERS ==="
  local iter_start=$SECONDS
  sudo blkzone reset /dev/nvme6n2 || true
  rm -rf /tmp/zenfs_aux/rocksdbtest
  ./../../rocksdb/plugin/zenfs/util/zenfs mkfs \
      --zbd=nvme6n2 --aux_path=/tmp/zenfs_aux/rocksdbtest \
      --finish_threshold=10 --force >/dev/null

  export LD_LIBRARY_PATH=../../jni:${LD_LIBRARY_PATH:-}
  export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/liburing.so.2:/lib/x86_64-linux-gnu/libzbd.so.2:/lib/x86_64-linux-gnu/libgflags.so.2.2
  export MAVEN_OPTS="-Djava.library.path=../../jni"

  mvn -q -P"$MVN_PROFILE" exec:java -Dexec.mainClass=main.Main -Dexec.args="local $CONFIG_ACTIVE" > "$log" 2>&1 || true

  # Whole-iteration wall clock (reset + mkfs + load + test), distinct from
  # CobraBench's own "total runtime" line which only covers the test phase.
  local iter_elapsed=$(( SECONDS - iter_start ))
  echo "[ITER_RUNTIME] wall_clock_s=$iter_elapsed" >> "$log"

  echo "-- summary --"
  grep -E "^(#Txn=|Throughput:|total runtime|\[IO_EVAL\]|\[ITER_RUNTIME\])" "$log" | sed 's/^/  /'
  echo
}

run_tier() {
  local tier=$1
  local value=$2
  local i
  for (( i=1; i<=ITERS; i++ )); do
    run_iter "$tier" "$value" "$i"
  done
}

stats() {
  awk '{ n++; sum+=$1; sq+=$1*$1 }
       END { if (!n) { print "0 0"; exit }
             m=sum/n; v=sq/n - m*m; if (v<0) v=0; printf("%.2f %.2f\n", m, sqrt(v)) }'
}

aggregate_tier() {
  local tier=$1
  local value=$2
  local files=( "$RUN_DIR"/${BENCH}_${tier}_${KNOB}${value}_iter*.log )
  echo "--- tier=$tier $KNOB=$value over $ITERS iters ---"

  local tp sc fm wa tr ir
  tp=$(grep -h '^Throughput: '     "${files[@]}" | awk '{gsub(",","",$2); print $2}' | stats)
  sc=$(grep -h '^#Txn='            "${files[@]}" | grep -oE 'success%=[0-9.]+' | cut -d= -f2 | stats)
  fm=$(grep -h '^\[IO_EVAL\]'      "${files[@]}" | grep -oE 'flash_MiBs=[0-9.]+' | cut -d= -f2 | stats)
  wa=$(grep -h '^\[IO_EVAL\]'      "${files[@]}" | grep -oE 'write_amp=[0-9.]+' | cut -d= -f2 | stats)
  tr=$(grep -h '^total runtime: '  "${files[@]}" | awk '{gsub(",","",$3); print $3}' | stats)
  ir=$(grep -h '^\[ITER_RUNTIME\]' "${files[@]}" | grep -oE 'wall_clock_s=[0-9.]+' | cut -d= -f2 | stats)

  printf "  goodput_tps   = %s\n" "$tp"
  printf "  success_pct   = %s\n" "$sc"
  printf "  flash_MiBs    = %s\n" "$fm"
  printf "  write_amp     = %s\n" "$wa"
  printf "  test_ms       = %s\n" "$tr"
  printf "  iter_wall_s   = %s\n" "$ir"
  echo
}

mvn -q -P"$MVN_PROFILE" package -DskipTests >/dev/null

run_tier low    "$LOW"
run_tier medium "$MED"
run_tier high   "$HIGH"

echo "================ Aggregate ($BENCH) ================"
aggregate_tier low    "$LOW"
aggregate_tier medium "$MED"
aggregate_tier high   "$HIGH"

echo "Logs: $RUN_DIR"