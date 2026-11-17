#!/bin/bash
source "$(dirname "$0")/common.sh"
need_cluster

SWEEP="${SWEEP:-384 512 640 768 896}"

outside() {
  docker start "$OUTSIDE" >/dev/null || return 1
  for _ in $(seq 1 60); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$OUTSIDE_URL/health/live")" = 200 ] && return 0
    sleep 1
  done
  return 1
}

top_loop() {
  while sleep 3; do
    kubectl -n "$NS" top pod --no-headers 2>/dev/null | sed "s/^/$(date +%H:%M:%S) /"
  done
}

state() {
  kubectl -n "$NS" get pod "$1" -o jsonpath='{.status.containerStatuses[0].state.terminated.reason} {.status.containerStatuses[0].state.terminated.exitCode} {.status.containerStatuses[0].state.terminated.startedAt} {.status.containerStatuses[0].state.terminated.finishedAt}'
}

seconds() {
  perl -MTime::Local -e 'sub t { $_[0] =~ /(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)/; timegm($6, $5, $4, $3, $2 - 1, $1) } print t($ARGV[1]) - t($ARGV[0])' "$1" "$2"
}

body() {
  title "хранилище пока снаружи кластера: контейнер rustfs из дз-3"
  outside || { note "rustfs из дз-3 не отвечает на $OUTSIDE_URL"; return 1; }
  run docker ps --filter "name=^${OUTSIDE}\$" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
  run cat k8s/01-s3-outside.yaml
  run kubectl apply -f k8s/01-s3-outside.yaml || return 1
  clean_jobs

  title "первый запуск: предел памяти 256Mi взят наугад"
  run cat k8s/10-whole-oom.yaml
  run kubectl apply -f k8s/10-whole-oom.yaml || return 1
  finished pairs-oom
  pod=$(pod_of pairs-oom)
  node=$(k get pod "$pod" -o jsonpath='{.spec.nodeName}')
  run kubectl -n "$NS" get pods -o wide
  sh_run "kubectl -n $NS describe pod $pod | sed -n '/^    State:/,/^    Requests:/p;/^QoS Class:/p'"
  run kubectl -n "$NS" logs "$pod"
  run kubectl -n "$NS" get job pairs-oom -o 'jsonpath={range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
  sh_run "docker exec $node dmesg | grep 'Memory cgroup out of memory' | tail -n 1 | cut -c1-200"
  keep pairs-oom 01_oom
  k describe pod "$pod" > logs/01_oom/describe-pairs-oom.txt

  title "замер пика: тот же расчёт с пределом 2Gi, три запуска"
  peaks=""
  for i in 1 2 3; do
    sed "s/name: pairs-oom/name: pairs-measure-$i/; s/memory: 256Mi/memory: 2Gi/" k8s/10-whole-oom.yaml > "$OUT/tmp.yaml"
    printf '\n$ sed "s/name: pairs-oom/name: pairs-measure-%s/; s/memory: 256Mi/memory: 2Gi/" k8s/10-whole-oom.yaml | kubectl apply -f -\n' "$i"
    kubectl apply -f "$OUT/tmp.yaml" || return 1
    if [ "$i" = 1 ]; then
      top_loop > logs/01_oom/top-measure-1.txt &
      top_pid=$!
    fi
    finished "pairs-measure-$i" || { k logs "job/pairs-measure-$i" | tail -n 20; return 1; }
    if [ "$i" = 1 ]; then
      kill "$top_pid" 2>/dev/null
      wait "$top_pid" 2>/dev/null
      run kubectl -n "$NS" logs job/pairs-measure-1
    else
      sh_run "kubectl -n $NS logs job/pairs-measure-$i | grep -E '^(время|топ-10 пар совпадает|память|процессор)'"
    fi
    keep "pairs-measure-$i" 01_oom
    peaks="$peaks $(peak_of "pairs-measure-$i")"
  done
  rm -f "$OUT/tmp.yaml"
  max=$(printf '%s\n' $peaks | sort -n | tail -n 1)
  limit=$(limit_for "$max")
  note ""
  note "пики трёх запусков, миб:$peaks; максимум $max"
  note "предел = максимум * 1.25 с округлением вверх до 64 миб = $limit миб"
  topmax=$(awk '{ v = $4; sub(/Mi/, "", v); if (v + 0 > m) m = v + 0 } END { print m + 0 }' logs/01_oom/top-measure-1.txt)
  topn=$(wc -l < logs/01_oom/top-measure-1.txt | tr -d ' ')
  sh_run "cat logs/01_oom/top-measure-1.txt"
  note "kubectl top за первый запуск: замеров $topn, максимум $topmax миб, а memory.peak $(echo $peaks | cut -d' ' -f1) миб"

  title "границы: тот же расчёт с разными пределами"
  printf '%s\n' "предел,исход,код,время,пик" > logs/01_oom/sweep.csv
  : > "$OUT/sweep.tex"
  for m in 256 $SWEEP "$limit"; do
    name=pairs-mem-$m
    if [ "$m" = 256 ]; then
      name=pairs-oom
    else
      sed "s/name: pairs-oom/name: $name/; s/memory: 256Mi/memory: ${m}Mi/" k8s/10-whole-oom.yaml | kubectl apply -f - >/dev/null || return 1
      finished "$name"
      keep "$name" 01_oom
    fi
    p=$(pod_of "$name")
    set -- $(state "$p")
    took=$(seconds "$3" "$4")
    peak=$(peak_of "$name")
    printf 'предел %4s миб: %-9s код %-3s работал %3s с, пик %s\n' "$m" "$1" "$2" "$took" "${peak:--}"
    printf '%s\n' "$m,$1,$2,$took,${peak:-}" >> logs/01_oom/sweep.csv
    printf '%s & \\texttt{%s} & %s & %s & %s \\\\\n' "$m" "$1" "$2" "$took" "${peak:----}" >> "$OUT/sweep.tex"
  done
  run kubectl -n "$NS" get pods

  title "итоговый запуск с подобранным пределом ${limit}Mi"
  set_memory "$limit" k8s/12-whole.yaml k8s/52-urgent.yaml
  run cat k8s/12-whole.yaml
  run kubectl apply -f k8s/12-whole.yaml || return 1
  finished pairs-whole || { k logs job/pairs-whole | tail -n 20; return 1; }
  pod=$(pod_of pairs-whole)
  run kubectl -n "$NS" get job pairs-whole -o wide
  sh_run "kubectl -n $NS describe pod $pod | sed -n '/^    State:/,/^    Requests:/p;/^QoS Class:/p'"
  run kubectl -n "$NS" logs "$pod"
  keep pairs-whole 01_oom
  k describe pod "$pod" > logs/01_oom/describe-pairs-whole.txt
  final=$(peak_of pairs-whole)
  vars oom wholePeaks "$(echo $peaks | sed 's/ /, /g')" wholePeakMax "$max" wholeLimit "$limit" wholeFinalPeak "$final" \
    wholeFinalPct "$(( (final * 100 + limit / 2) / limit ))" topMax "$topmax" topCount "$topn" topPeak "$(echo $peaks | cut -d' ' -f1)"
  clean_jobs
}

clear 2>/dev/null
rm -rf logs/01_oom
mkdir -p logs/01_oom
capture 01_oom body
