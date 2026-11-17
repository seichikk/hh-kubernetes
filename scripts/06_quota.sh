#!/bin/bash
source "$(dirname "$0")/common.sh"
need_cluster

body() {
  clean_jobs
  title "квота на пространство имён hh"
  run cat k8s/60-quota.yaml
  run kubectl apply -f k8s/60-quota.yaml || return 1
  sleep 2
  run kubectl -n "$NS" describe resourcequota hh-quota

  title "под без заявок и пределов"
  run kubectl -n "$NS" run no-limits --image="$IMG" --restart=Never -- ls

  title "та же задача из 12 частей, теперь под квотой"
  s3_mem_start logs/06_quota/rustfs-mem.txt
  watch_pods logs/06_quota/watch.log
  t_map=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  run kubectl apply -f k8s/40-map-all.yaml || return 1
  sleep 8
  run kubectl -n "$NS" get pods -o wide
  run kubectl -n "$NS" describe resourcequota hh-quota
  sh_run "kubectl -n $NS describe job pairs-map-all | sed -n '/^Parallelism:/p;/^Pods Statuses:/p;/^Events:/,\$p' | cut -c1-260"

  title "срочная задача с высоким приоритетом при занятой квоте"
  t_urgent=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  note "$(clock) kubectl apply -f k8s/52-urgent.yaml"
  kubectl apply -f k8s/52-urgent.yaml || return 1
  sleep 5
  run kubectl -n "$NS" get jobs -o wide
  sh_run "kubectl -n $NS describe job pairs-urgent | sed -n '/^Pods Statuses:/p;/^Events:/,\$p' | cut -c1-260"
  finished pairs-map-all || { k get pods; stop_watch; return 1; }
  note ""
  note "$(clock) pairs-map-all завершена"
  finished pairs-urgent || { k describe job pairs-urgent | tail -n 20; stop_watch; return 1; }
  note "$(clock) pairs-urgent завершена"
  stop_watch
  s3_mem_stop
  run kubectl -n "$NS" get jobs -o wide
  sh_run "kubectl -n $NS get events --field-selector reason=FailedCreate -o custom-columns='JOB:.involvedObject.name,COUNT:.count' --no-headers | awk '{ n[\$1] += \$2 } END { for (j in n) print j \": отказов exceeded quota \" n[j] }'"
  keep pairs-map-all 06_quota
  keep pairs-urgent 06_quota
  k get events --sort-by=.lastTimestamp > logs/06_quota/events.txt
  sh_run "python3 scripts/timeline.py logs/06_quota/watch.log quota --urgent pairs-urgent --since pairs-map-all=$t_map --since pairs-urgent=$t_urgent"

  title "квота снята"
  run kubectl -n "$NS" delete resourcequota hh-quota
}

clear 2>/dev/null
rm -rf logs/06_quota
mkdir -p logs/06_quota
capture 06_quota body
