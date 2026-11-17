#!/bin/bash
source "$(dirname "$0")/common.sh"
need_cluster

running() {
  k get pods --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' '
}

body() {
  clean_jobs
  title "два класса приоритета"
  run cat k8s/50-priority.yaml
  run kubectl apply -f k8s/50-priority.yaml || return 1
  run kubectl get priorityclass

  title "плановая задача с низким приоритетом занимает оба рабочих узла"
  sh_run "diff k8s/40-map-all.yaml k8s/51-map-low.yaml"
  s3_mem_start logs/05_preempt/rustfs-mem.txt
  watch_pods logs/05_preempt/watch.log
  run kubectl apply -f k8s/51-map-low.yaml || return 1
  for _ in $(seq 1 60); do
    [ "$(running)" -ge 6 ] && break
    sleep 1
  done
  sleep 3
  run kubectl -n "$NS" get pods -o wide

  title "срочная задача с высоким приоритетом: ей нужно 3 cpu на одном узле"
  run cat k8s/52-urgent.yaml
  note ""
  note "$(clock) kubectl apply -f k8s/52-urgent.yaml"
  kubectl apply -f k8s/52-urgent.yaml || return 1
  sleep 4
  note "$(clock)"
  run kubectl -n "$NS" get pods -o wide
  urgent=$(pod_of pairs-urgent)
  sh_run "kubectl -n $NS get events --field-selector reason=Preempted -o custom-columns='TIME:.lastTimestamp,POD:.involvedObject.name,MESSAGE:.message'"
  sh_run "kubectl -n $NS describe pod $urgent | sed -n '/^Priority/p;/^Events:/,\$p'"
  finished pairs-urgent || { k logs job/pairs-urgent | tail -n 20; stop_watch; return 1; }
  sh_run "kubectl -n $NS logs job/pairs-urgent | grep -E '^(время|k[123]\.csv|топ-10 пар совпадает|память|процессор)'"
  finished pairs-low || { k get pods; stop_watch; return 1; }
  stop_watch
  s3_mem_stop
  run kubectl -n "$NS" get jobs -o wide
  run kubectl -n "$NS" get pods -o wide
  run kubectl -n "$NS" get job pairs-low -o 'jsonpath={.status.succeeded} готово, {.status.failed} в счётчике ошибок{"\n"}'
  keep pairs-low 05_preempt
  keep pairs-urgent 05_preempt
  k get events --sort-by=.lastTimestamp > logs/05_preempt/events.txt
  sh_run "python3 scripts/timeline.py logs/05_preempt/watch.log preempt --urgent pairs-urgent"

  title "reduce по частям плановой задачи"
  k delete job pairs-reduce >/dev/null 2>&1
  run kubectl apply -f k8s/32-reduce.yaml || return 1
  finished pairs-reduce || { k logs job/pairs-reduce | tail -n 20; return 1; }
  sh_run "kubectl -n $NS logs job/pairs-reduce | grep -E '^(части|частей|k[123]\.csv|топ-10 пар совпадает)'"
  keep pairs-reduce 05_preempt
}

clear 2>/dev/null
rm -rf logs/05_preempt
mkdir -p logs/05_preempt
capture 05_preempt body
