#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_ROOT="$ROOT_DIR/perf-logs"
LATEST_FILE="$LOG_ROOT/latest"
PROC_MATCH='GaiTerm.app/Contents/MacOS/ghostty'

usage() {
  cat <<'USAGE'
Usage:
  scripts/gaiterm-perf-capture.sh start [interval_seconds] [app_cpu_spike] [child_cpu_spike]
  scripts/gaiterm-perf-capture.sh stop [run_dir]
  scripts/gaiterm-perf-capture.sh summary [run_dir]

Default interval is 2s. Default spike thresholds: app 120%, child 80%.
USAGE
}

find_gaiterm_pid() {
  local pids
  pids="$(pgrep -f "$PROC_MATCH" 2>/dev/null || true)"
  awk 'NF { print; exit }' <<<"$pids"
}

children_of() {
  pgrep -P "$1" 2>/dev/null || true
}

descendants_of() {
  local root="$1"
  local child
  for child in $(children_of "$root"); do
    echo "$child"
    descendants_of "$child"
  done
}

ps_pid_csv() {
  local pids="$*"
  echo "$pids" | tr ' ' ','
}

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

load_fields() {
  sysctl -n vm.loadavg | tr -d '{}'
}

safe_num() {
  awk -v v="${1:-0}" 'BEGIN { if (v == "" || v == "-") print 0; else print v + 0 }'
}

start_capture() {
  mkdir -p "$LOG_ROOT"

  local interval="${1:-2}"
  local app_spike="${2:-120}"
  local child_spike="${3:-80}"
  local run_dir="$LOG_ROOT/gaiterm-$(date +"%Y%m%d-%H%M%S")"
  mkdir -p "$run_dir/samples" "$run_dir/snapshots"

  local pid=""
  if command -v tmux >/dev/null 2>&1; then
    local session="gaiterm-perf-$(date +"%H%M%S")"
    echo "$session" >"$run_dir/tmux.session"
    tmux new-session -d -s "$session" -c "$ROOT_DIR" \
      "/bin/bash '$0' collect '$run_dir' '$interval' '$app_spike' '$child_spike'"
    for _ in {1..20}; do
      [[ -s "$run_dir/collector.pid" ]] && break
      sleep 0.1
    done
    pid="$(cat "$run_dir/collector.pid" 2>/dev/null || true)"
  else
    nohup /bin/bash "$0" collect "$run_dir" "$interval" "$app_spike" "$child_spike" \
      </dev/null >"$run_dir/collector.out" 2>"$run_dir/collector.err" &
    pid="$!"
    echo "$pid" >"$run_dir/collector.pid"
  fi
  ln -sfn "$run_dir" "$LATEST_FILE"

  echo "Started GaiTerm perf capture"
  echo "Run dir: $run_dir"
  echo "Collector PID: ${pid:-pending}"
  if [[ -f "$run_dir/tmux.session" ]]; then
    echo "tmux session: $(cat "$run_dir/tmux.session")"
  fi
}

stop_capture() {
  local run_dir="${1:-}"
  if [[ -z "$run_dir" ]]; then
    if [[ ! -e "$LATEST_FILE" ]]; then
      echo "No latest perf capture found." >&2
      exit 1
    fi
    run_dir="$(readlink "$LATEST_FILE")"
  fi

  if [[ ! -f "$run_dir/collector.pid" ]]; then
    echo "No collector.pid in $run_dir" >&2
    exit 1
  fi

  local pid
  pid="$(cat "$run_dir/collector.pid")"
  local session=""
  if [[ -f "$run_dir/tmux.session" ]]; then
    session="$(cat "$run_dir/tmux.session")"
  fi

  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in {1..30}; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi

  if [[ -n "$session" ]] && command -v tmux >/dev/null 2>&1; then
    tmux kill-session -t "$session" 2>/dev/null || true
  fi

  "$0" summary "$run_dir"
}

collect_loop() {
  local run_dir="$1"
  local interval="$2"
  local app_spike="$3"
  local child_spike="$4"

  trap '' HUP
  echo "$$" >"$run_dir/collector.pid"
  cat >"$run_dir/run.env" <<EOF
started_at=$(now_iso)
interval_seconds=$interval
app_cpu_spike=$app_spike
child_cpu_spike=$child_spike
proc_match=$PROC_MATCH
EOF

  printf "ts\tpid\tcpu\tmem\trss_kb\tvsz_kb\tthreads\tfds\tptmx\tchild_count\tchild_cpu\tchild_rss_kb\tload1\tload5\tload15\tstate\n" \
    >"$run_dir/process.tsv"
  printf "ts\tpid\tppid\tcpu\tmem\trss_kb\tcomm\tcommand\n" >"$run_dir/children.tsv"
  printf "ts\treason\tpid\tcpu\tfile\n" >"$run_dir/samples.tsv"
  printf "ts\tpid\tppid\tcpu\tmem\trss_kb\tcommand\n" >"$run_dir/global-top.tsv"

  local log_pid=""
  log stream --style compact \
    --predicate 'process == "ghostty" OR process == "GaiTerm" OR process CONTAINS "gaiterm"' \
    >"$run_dir/unified-log.txt" 2>"$run_dir/unified-log.err" &
  log_pid="$!"

  cleanup() {
    if [[ -n "$log_pid" ]] && kill -0 "$log_pid" 2>/dev/null; then
      kill "$log_pid" 2>/dev/null || true
    fi
    echo "stopped_at=$(now_iso)" >>"$run_dir/run.env"
  }
  trap cleanup EXIT
  trap 'exit 0' INT TERM

  local i=0
  local last_fds=0
  local last_ptmx=0
  local last_app_sample=0
  local last_child_sample=0

  while true; do
    local ts pid
    ts="$(now_iso)"
    pid="$(find_gaiterm_pid)"

    if [[ -z "$pid" ]]; then
      local load1 load5 load15
      read -r load1 load5 load15 _ <<<"$(load_fields)"
      printf "%s\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t%s\t%s\t%s\tmissing\n" \
        "$ts" "$load1" "$load5" "$load15" \
        >>"$run_dir/process.tsv"
      sleep "$interval"
      continue
    fi

    local line pid_v ppid_v cpu mem rss vsz state
    line="$(ps -o pid= -o ppid= -o pcpu= -o pmem= -o rss= -o vsz= -o state= -p "$pid" 2>/dev/null || true)"
    if [[ -z "$line" ]]; then
      sleep "$interval"
      continue
    fi
    read -r pid_v ppid_v cpu mem rss vsz state _ <<<"$line"
    cpu="$(safe_num "$cpu")"
    mem="$(safe_num "$mem")"
    rss="$(safe_num "$rss")"
    vsz="$(safe_num "$vsz")"

    local threads
    threads="$(ps -M -p "$pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"

    if (( i % 5 == 0 )); then
      last_fds="$(lsof -p "$pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
      last_ptmx="$(lsof -p "$pid" 2>/dev/null | awk '$NF ~ /^\/dev\/pt/ || $NF == "/dev/ptmx" { c++ } END { print c + 0 }')"
    fi

    local children child_csv child_count child_cpu child_rss
    children="$(descendants_of "$pid" | sort -n | tr '\n' ' ')"
    child_count="$(wc -w <<<"$children" | tr -d ' ')"
    child_cpu=0
    child_rss=0

    if [[ -n "${children// /}" ]]; then
      child_csv="$(ps_pid_csv $children)"
      local child_ps
      child_ps="$(ps -o pid= -o ppid= -o pcpu= -o pmem= -o rss= -o comm= -o command= -p "$child_csv" 2>/dev/null || true)"
      if [[ -n "$child_ps" ]]; then
        child_cpu="$(awk '{ s += $3 } END { print s + 0 }' <<<"$child_ps")"
        child_rss="$(awk '{ s += $5 } END { print s + 0 }' <<<"$child_ps")"
        awk -v ts="$ts" '
          {
            cmd = "";
            for (i = 7; i <= NF; i++) cmd = cmd (i == 7 ? "" : " ") $i;
            print ts "\t" $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" cmd;
          }
        ' <<<"$child_ps" >>"$run_dir/children.tsv"
      fi
    fi

    local load1 load5 load15
    read -r load1 load5 load15 _ <<<"$(load_fields)"
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$ts" "$pid" "$cpu" "$mem" "$rss" "$vsz" "$threads" "$last_fds" "$last_ptmx" \
      "$child_count" "$child_cpu" "$child_rss" "$load1" "$load5" "$load15" "$state" \
      >>"$run_dir/process.tsv"

    if (( i % 5 == 0 )); then
      local global_ps
      set +o pipefail
      global_ps="$(ps -axo pid= -o ppid= -o pcpu= -o pmem= -o rss= -o command= \
        | sort -k3 -nr | head -n 30)"
      set -o pipefail
      awk -v ts="$ts" '{
            cmd = "";
            for (i = 6; i <= NF; i++) cmd = cmd (i == 6 ? "" : " ") $i;
            print ts "\t" $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" cmd;
          }' <<<"$global_ps" >>"$run_dir/global-top.tsv"

      top -l 1 -pid "$pid" -stats pid,command,cpu,mem,threads,ports,time \
        >"$run_dir/snapshots/top-$ts.txt" 2>/dev/null || true
      ps -M -p "$pid" >"$run_dir/snapshots/threads-$ts.txt" 2>/dev/null || true
    fi

    local now_epoch
    now_epoch="$(date +%s)"
    if awk -v c="$cpu" -v t="$app_spike" 'BEGIN { exit !(c >= t) }' &&
       (( now_epoch - last_app_sample >= 20 )); then
      local file="$run_dir/samples/app-$ts-cpu-$cpu.txt"
      sample "$pid" 2 -mayDie -file "$file" >/dev/null 2>&1 || true
      printf "%s\tapp_cpu\t%s\t%s\t%s\n" "$ts" "$pid" "$cpu" "$file" >>"$run_dir/samples.tsv"
      last_app_sample="$now_epoch"
    fi

    if [[ -n "${children// /}" ]] &&
       awk -v c="$child_cpu" -v t="$child_spike" 'BEGIN { exit !(c >= t) }' &&
       (( now_epoch - last_child_sample >= 20 )); then
      local hot
      set +o pipefail
      hot="$(ps -o pid= -o pcpu= -p "$(ps_pid_csv $children)" 2>/dev/null | sort -k2 -nr | head -n 1 || true)"
      set -o pipefail
      if [[ -n "$hot" ]]; then
        local hot_pid hot_cpu
        read -r hot_pid hot_cpu _ <<<"$hot"
        local file="$run_dir/samples/child-$ts-pid-$hot_pid-cpu-$hot_cpu.txt"
        sample "$hot_pid" 2 -mayDie -file "$file" >/dev/null 2>&1 || true
        printf "%s\tchild_cpu\t%s\t%s\t%s\n" "$ts" "$hot_pid" "$hot_cpu" "$file" >>"$run_dir/samples.tsv"
        last_child_sample="$now_epoch"
      fi
    fi

    i=$((i + 1))
    sleep "$interval"
  done
}

summary() {
  local run_dir="${1:-}"
  if [[ -z "$run_dir" ]]; then
    if [[ ! -e "$LATEST_FILE" ]]; then
      echo "No latest perf capture found." >&2
      exit 1
    fi
    run_dir="$(readlink "$LATEST_FILE")"
  fi

  local out="$run_dir/summary.txt"
  {
    echo "GaiTerm perf summary"
    echo "Run dir: $run_dir"
    echo
    if [[ -f "$run_dir/run.env" ]]; then
      cat "$run_dir/run.env"
      echo
    fi

    echo "Peak app CPU:"
    awk -F '\t' 'NR == 2 || (NR > 1 && $3 > max) { max=$3; row=$0 } END { print row }' "$run_dir/process.tsv"
    echo

    echo "Peak child CPU total:"
    awk -F '\t' 'NR == 2 || (NR > 1 && $11 > max) { max=$11; row=$0 } END { print row }' "$run_dir/process.tsv"
    echo

    echo "Peak app RSS:"
    awk -F '\t' 'NR == 2 || (NR > 1 && $5 > max) { max=$5; row=$0 } END { print row }' "$run_dir/process.tsv"
    echo

    echo "Top child process spikes:"
    set +o pipefail
    awk -F '\t' 'NR > 1 {
      key=$7 " " $8;
      if ($4 > max[key]) { max[key]=$4; row[key]=$0 }
    } END {
      for (k in max) print max[k] "\t" row[k]
    }' "$run_dir/children.tsv" | sort -nr | head -n 20 || true
    set -o pipefail
    echo

    echo "Captured stack samples:"
    if [[ -f "$run_dir/samples.tsv" ]]; then
      tail -n +2 "$run_dir/samples.tsv"
    fi
  } | tee "$out"
}

cmd="${1:-}"
case "$cmd" in
  start)
    shift
    start_capture "$@"
    ;;
  stop)
    shift
    stop_capture "$@"
    ;;
  collect)
    shift
    collect_loop "$@"
    ;;
  summary)
    shift
    summary "$@"
    ;;
  *)
    usage
    exit 1
    ;;
esac
