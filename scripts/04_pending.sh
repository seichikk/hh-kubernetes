#!/bin/bash
source "$(dirname "$0")/common.sh"
need_cluster

body() {
  clean_jobs
  title "сколько cpu свободно на рабочих узлах"
  sh_run "kubectl describe nodes hh-worker hh-worker2 | grep -E '^Name:|^  cpu  |^  memory  '"

  title "все 12 частей сразу: parallelism 12, перед каждым чанком пауза 5 с"
  sh_run "diff k8s/31-map.yaml k8s/40-map-all.yaml"
  s3_mem_start logs/04_pending/rustfs-mem.txt
  watch_pods logs/04_pending/watch.log
  run kubectl apply -f k8s/40-map-all.yaml || return 1
  sleep 8
  run kubectl -n "$NS" get pods -o wide
  waiting=$(k get pods --field-selector=status.phase=Pending -o jsonpath='{.items[0].metadata.name}')
  sh_run "kubectl -n $NS describe pod $waiting | sed -n '/^Status:/p;/^Conditions:/,/^Volumes:/p;/^Events:/,\$p'"
  k describe pod "$waiting" > logs/04_pending/describe-pending.txt
  sh_run "kubectl describe node hh-worker | sed -n '/^Non-terminated Pods:/,/^Events:/p'"
  sh_run "kubectl describe node hh-worker2 | sed -n '/^Non-terminated Pods:/,/^Events:/p'"
  for _ in $(seq 1 40); do
    kubectl -n "$NS" top pods >/dev/null 2>&1 && break
    sleep 1
  done
  run kubectl -n "$NS" top pods
  run kubectl top nodes
  finished pairs-map-all || { k get pods; stop_watch; return 1; }
  stop_watch
  s3_mem_stop
  run kubectl -n "$NS" get job pairs-map-all -o wide
  run kubectl -n "$NS" get pods -o wide
  sh_run "kubectl -n $NS get events --field-selector reason=FailedScheduling -o custom-columns='TIME:.lastTimestamp,COUNT:.count,POD:.involvedObject.name,MESSAGE:.message' | cut -c1-170"
  keep pairs-map-all 04_pending
  k get events --sort-by=.lastTimestamp > logs/04_pending/events.txt
  sh_run "python3 scripts/timeline.py logs/04_pending/watch.log pending"

  title "reduce по частям этого запуска"
  k delete job pairs-reduce >/dev/null 2>&1
  run kubectl apply -f k8s/32-reduce.yaml || return 1
  finished pairs-reduce || { k logs job/pairs-reduce | tail -n 20; return 1; }
  sh_run "kubectl -n $NS logs job/pairs-reduce | grep -E '^(части|частей|k[123]\.csv|топ-10 пар совпадает)'"
  keep pairs-reduce 04_pending
}

clear 2>/dev/null
rm -rf logs/04_pending
mkdir -p logs/04_pending
capture 04_pending body
