#!/usr/bin/env bash
set -Eeuo pipefail

MODE=${1:?usage: run_fb_standalone.sh <nodiscard|online_discard|fstrim>}
BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

DEVICE=${DEVICE:-/dev/nvme1n1}
MNT=${MNT:-/media/nvme}
FB_DIR=${FB_DIR:-$MNT/filebench}
LOG_DIR="$BASE_DIR/logs/$(date +%Y%m%d_%H%M%S)_${MODE}_standalone"
WML_DIR="$LOG_DIR/wml"
SETUP_LOG="$LOG_DIR/setup.log"
RUN_LOG="$LOG_DIR/run.log"

# 요청하신 핵심 파라미터 변경점
RUNTIME_SEC=300
FB_PREALLOC=80

# Filebench 파라미터 (기존 유지)
FB_LOGICAL_GIB=24
FB_SET_COUNT=1
FB_SET_ENTRIES=163840 # 20GiB / 128KiB 기준
FB_MEANFILE_KIB=128
FB_THREADS=50
FB_DIRWIDTH=20
FB_IOSIZE=1m
FB_APPEND=16k

BLKTRACE_PID=""
BLKTRACE_DIR="$LOG_DIR/blktrace_raw"
BLKTRACE_OUT="$LOG_DIR/blktrace_write_latency.csv"

mkdir -p "$LOG_DIR" "$WML_DIR"

cleanup() {
  local pid
  for pid in "${BLKTRACE_PID:-}" "${FILEBENCH_PID:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
}

trap cleanup EXIT

start_blktrace() {
  echo "[$(date '+%F %T')] start blktrace on $DEVICE"
  mkdir -p "$BLKTRACE_DIR"
  blktrace -d "$DEVICE" -D "$BLKTRACE_DIR" &
  BLKTRACE_PID=$!
}

stop_blktrace() {
  if [[ -n "$BLKTRACE_PID" ]] && kill -0 "$BLKTRACE_PID" 2>/dev/null; then
    echo "[$(date '+%F %T')] stop blktrace"
    kill "$BLKTRACE_PID" 2>/dev/null || true
    wait "$BLKTRACE_PID" 2>/dev/null || true
  fi
  BLKTRACE_PID=""
}

parse_blktrace_write_latency() {
  local devbase
  devbase=$(basename "$(readlink -f "$DEVICE")")
  echo "[$(date '+%F %T')] parse blktrace for write latency"

  blkparse -i "$BLKTRACE_DIR/$devbase" \
    -f "%T.%9t %a %d %S %N\n" \
    -o "$LOG_DIR/blkparse_all.txt" \
    -d "$LOG_DIR/blkparse_merged.bin" -q 2>/dev/null || true

  python3 - "$LOG_DIR/blkparse_all.txt" "$BLKTRACE_OUT" <<'PYEOF'
import sys

infile, outfile = sys.argv[1], sys.argv[2]
issued = {}
latencies = []

with open(infile, 'r') as f:
    for line in f:
        parts = line.strip().split()
        if len(parts) < 5:
            continue
        ts_str, action, rwbs, sector, nbytes = parts[0], parts[1], parts[2], parts[3], parts[4]
        if 'W' not in rwbs:
            continue
        try:
            ts = float(ts_str)
            sector = int(sector)
            nbytes = int(nbytes)
        except ValueError:
            continue
        key = (sector, nbytes)
        if action == 'D':
            issued[key] = ts
        elif action == 'C' and key in issued:
            latency = ts - issued.pop(key)
            latencies.append((ts, sector, nbytes, latency))

with open(outfile, 'w') as f:
    f.write("timestamp_sec,sector,bytes,latency_sec\n")
    for ts, sec, nb, lat in latencies:
        f.write(f"{ts:.9f},{sec},{nb},{lat:.9f}\n")

print(f"Total write completions: {len(latencies)}")
if latencies:
    lats = [l[3] for l in latencies]
    print(f"Min: {min(lats)*1000:.3f} ms  Max: {max(lats)*1000:.3f} ms  Avg: {(sum(lats)/len(lats))*1000:.3f} ms")
PYEOF

  echo "[$(date '+%F %T')] write latency CSV: $BLKTRACE_OUT"
}


run_nvme_read() {
  local stage=$1
  echo "[$(date '+%F %T')] nvme read ($stage)"
  nvme read "$DEVICE" -c 77 -s 77 -z 4096 >> "$SETUP_LOG" 2>&1 || true
}

# 1. 환경 초기화 (ext4 생성 및 마운트)
if mountpoint -q "$MNT"; then umount "$MNT"; fi
blkdiscard -f "$DEVICE"
mkfs.ext4 -F -m 0 -E lazy_itable_init=0,lazy_journal_init=0 "$DEVICE" >/dev/null 2>&1

run_nvme_read "before mount"

echo 0 > /proc/sys/kernel/randomize_va_space

opts="noatime,nodiratime,nodelalloc"
if [[ "$MODE" == "nodiscard" || "$MODE" == "fstrim" ]]; then opts+=",nodiscard"; fi
if [[ "$MODE" == "online_discard" ]]; then opts+=",discard"; fi

mount -t ext4 -o "$opts" "$DEVICE" "$MNT"
mkdir -p "$FB_DIR"

# 2. Filebench WML 스크립트 생성 (기존 파이썬 스크립트 재사용)
python3 "$BASE_DIR/mk_wml.py" \
  --out-dir "$WML_DIR" --fb-dir "$FB_DIR" --set-count "$FB_SET_COUNT" \
  --entries-per-set "$FB_SET_ENTRIES" --prealloc "$FB_PREALLOC" \
  --dirwidth "$FB_DIRWIDTH" --mean-file-kib "$FB_MEANFILE_KIB" \
  --runtime-sec "$RUNTIME_SEC" --iosize "$FB_IOSIZE" \
  --append-size "$FB_APPEND" --threads-total "$FB_THREADS"

# 3. Filebench 실행 (이때 내부적으로 Prealloc 단계가 먼저 수행됨)
echo "[$(date '+%F %T')] Start Filebench (Preallocating 80%...)"
stdbuf -oL -eL filebench -f "$WML_DIR/run.f" > "$RUN_LOG" 2>&1 &
FILEBENCH_PID=$!

# 4. Prealloc이 완료되고 메인 워크로드가 시작('Running...')될 때까지 대기
while kill -0 "$FILEBENCH_PID" 2>/dev/null; do
  if grep -Fq 'Running...' "$RUN_LOG" 2>/dev/null; then
    break
  fi
  sleep 1
done

# 5. Prealloc 완료 직후 (Fileserver 워크로드 본격 시작 시점)
echo "[$(date '+%F %T')] Prealloc Done. Workload Running for ${RUNTIME_SEC}s..."
run_nvme_read "after prealloc (runtime started)"

start_blktrace

# 6. 워크로드 실행 (300초) 완료 대기
wait "$FILEBENCH_PID"

# 7. 종료 후 최종 확인
echo "[$(date '+%F %T')] Workload Finished."
run_nvme_read "final"
stop_blktrace                           # ← 추가: filebench 끝나면 blktrace 중지
parse_blktrace_write_latency            # ← 추가: D→C write latency CSV 생성

sync

echo "Done. Check logs at $LOG_DIR"
