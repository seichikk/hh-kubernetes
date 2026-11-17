#!/bin/bash

LAB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$LAB" || exit 1

CLUSTER=hh
NS=hh
S3NS=hh-s3
IMG=hh-k8s:1
OUTSIDE=rustfs
OUTSIDE_URL=http://127.0.0.1:19000
METRICS=https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.1/components.yaml
HW3="${HW3:-$LAB/../hh-mapreduce/hh-mapreduce}"
OUT="$LAB/report/out"
mkdir -p "$OUT" "$LAB/logs" "$LAB/results"

title() {
  printf '\n==== %s ====\n' "$*"
}

note() {
  printf '%s\n' "$*"
}

shown() {
  local a out=""
  for a in "$@"; do
    case "$a" in
      *" "* | *"|"* | *"*"* | *"["*) out="$out '$a'" ;;
      *) out="$out $a" ;;
    esac
  done
  printf '%s' "${out# }"
}

run() {
  printf '\n$ %s\n' "$(shown "$@")"
  "$@"
}

sh_run() {
  printf '\n$ %s\n' "$1"
  bash -c "$1"
}

k() {
  kubectl -n "$NS" "$@"
}

clock() {
  perl -MTime::HiRes=time -MPOSIX=strftime -e '$t = time; printf "%s.%03d\n", strftime("%H:%M:%S", localtime $t), ($t - int $t) * 1000'
}

clean_out() {
  [ -f "$1" ] || return 0
  perl -CSD -i -pe 's/\e\[[0-9;?]*[A-Za-z]//g; s/\r//g; s/\x{2713}/+/g; s/\x{2022}/-/g; s/[\x{1F000}-\x{1FFFF}\x{FE0F}\x{2600}-\x{27BF}]\s?//g; s/[^\x{09}\x{0A}\x{20}-\x{7E}\x{401}\x{410}-\x{44F}\x{451}\x{AB}\x{BB}\x{2013}\x{2014}\x{2116}]/?/g' "$1" 2>/dev/null
  expand "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

capture() {
  local name="$1"
  shift
  "$@" 2>&1 | tee "$OUT/$name.txt"
  local rc=${PIPESTATUS[0]}
  clean_out "$OUT/$name.txt"
  return $rc
}

vars() {
  local name="$1"
  shift
  : > "$OUT/vars-$name.tex"
  while [ $# -gt 1 ]; do
    printf '\\renewcommand{\\%s}{%s}\n' "$1" "$2" >> "$OUT/vars-$name.tex"
    shift 2
  done
}

finished() {
  local i state
  for i in $(seq 1 "${2:-900}"); do
    state=$(kubectl -n "${3:-$NS}" get job "$1" -o jsonpath='{.status.conditions[?(@.status=="True")].type}' 2>/dev/null)
    case "$state" in
      *Complete*) return 0 ;;
      *Failed*) return 1 ;;
    esac
    sleep 1
  done
  return 2
}

keep() {
  local p ns="${3:-$NS}"
  mkdir -p "logs/$2"
  for p in $(kubectl -n "$ns" get pods -l job-name="$1" -o name); do
    kubectl -n "$ns" logs "$p" > "logs/$2/${p#pod/}.log" 2>&1
  done
}

pod_of() {
  kubectl -n "${2:-$NS}" get pods -l job-name="$1" -o jsonpath='{.items[0].metadata.name}'
}

peak_of() {
  kubectl -n "${2:-$NS}" logs "job/$1" 2>/dev/null | sed -n 's/^память контейнера: пик \([0-9]*\) миб.*/\1/p' | tail -n 1
}

limit_for() {
  echo $(( ($1 * 125 / 100 + 63) / 64 * 64 ))
}

set_memory() {
  local v="$1" f
  shift
  for f in "$@"; do
    perl -pi -e "s/memory: \\d+\\w+/memory: ${v}Mi/" "$f"
  done
}

watch_pods() {
  mkdir -p "$(dirname "$1")"
  (
    kubectl -n "$NS" get pods --watch --no-headers \
      -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,NODE:.spec.nodeName,DEL:.metadata.deletionTimestamp,WHY:.status.conditions[?(@.type=="DisruptionTarget")].reason' 2>/dev/null \
      | perl -MTime::HiRes=time -ne 'BEGIN { $| = 1 } printf "%.3f %s", time, $_' > "$1"
  ) &
  WATCH=$!
  sleep 1
}

stop_watch() {
  sleep 1
  pkill -P "$WATCH" 2>/dev/null
  kill "$WATCH" 2>/dev/null
  wait "$WATCH" 2>/dev/null
}

clean_jobs() {
  kubectl -n "$NS" delete job --all --wait=true >/dev/null 2>&1
  kubectl -n "$NS" wait --for=delete pod --all --timeout=120s >/dev/null 2>&1
  kubectl -n "$NS" delete events --all >/dev/null 2>&1
}

s3_mem_start() {
  S3MEM="$1"
  S3RESTARTS=$(kubectl -n "$S3NS" get pod rustfs-0 -o jsonpath='{.status.containerStatuses[0].restartCount}')
  kubectl -n "$S3NS" exec rustfs-0 -- sh -c 'while sleep 0.5; do echo $(grep "^anon " /sys/fs/cgroup/memory.stat | cut -d" " -f2) $(cat /sys/fs/cgroup/memory.current); done' > "$S3MEM" 2>/dev/null &
  S3PID=$!
}

s3_mem_stop() {
  kill "$S3PID" 2>/dev/null
  wait "$S3PID" 2>/dev/null
  local now max
  now=$(kubectl -n "$S3NS" get pod rustfs-0 -o jsonpath='{.status.containerStatuses[0].restartCount}')
  max=$(kubectl -n "$S3NS" get pod rustfs-0 -o jsonpath='{.spec.containers[0].resources.limits.memory}')
  awk -v r=$((now - S3RESTARTS)) -v m="$max" '{ if ($1 > a) a = $1; if ($2 > t) t = $2 }
    END { printf "rustfs-0: перезапусков за опыт %d, anon до %.0f миб, вместе с кэшем до %.0f миб, предел %s, замеров %d\n", r, a / 1048576, t / 1048576, m, NR }' "$S3MEM"
}

need_cluster() {
  kubectl --context "kind-$CLUSTER" get nodes >/dev/null 2>&1 || { note "нет кластера kind-$CLUSTER: bash scripts/00_cluster.sh"; exit 1; }
  kubectl config use-context "kind-$CLUSTER" >/dev/null
}
