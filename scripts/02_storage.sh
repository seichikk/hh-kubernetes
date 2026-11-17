#!/bin/bash
source "$(dirname "$0")/common.sh"
need_cluster

body() {
  title "rustfs из дз-2 внутри кластера: statefulset с четырьмя томами"
  run cat k8s/20-rustfs.yaml
  run kubectl apply -f k8s/20-rustfs.yaml || return 1
  run kubectl -n "$S3NS" rollout status statefulset/rustfs --timeout=300s || return 1
  run kubectl -n "$S3NS" get statefulset,pods,svc,pvc -o wide
  run kubectl get pv
  sh_run "kubectl -n $S3NS logs rustfs-0 | grep -v WARNING"

  title "перенос бакета hh-lake из хранилища на хосте"
  docker start "$OUTSIDE" >/dev/null
  kubectl -n "$S3NS" delete job s3-copy >/dev/null 2>&1
  run cat k8s/21-copy.yaml
  run kubectl apply -f k8s/21-copy.yaml || return 1
  finished s3-copy 900 "$S3NS" || { kubectl -n "$S3NS" logs job/s3-copy | tail -n 20; return 1; }
  run kubectl -n "$S3NS" logs job/s3-copy
  keep s3-copy 02_storage "$S3NS"
  sh_run "shasum -a 256 $HW3/results/mapreduce/k2.csv"

  title "что лежит на томах"
  sh_run "kubectl -n $S3NS exec rustfs-0 -- du -sm /data/rustfs1 /data/rustfs2 /data/rustfs3 /data/rustfs4"
  sh_run "kubectl -n $S3NS exec rustfs-0 -- sh -c 'ls -l /data/rustfs1/hh-lake/raw/it_vacancies_2024.csv/*/ | head -n 6'"
  sh_run "kubectl -n $S3NS exec rustfs-0 -- sh -c 'grep -E \"^(anon|file) \" /sys/fs/cgroup/memory.stat; cat /sys/fs/cgroup/memory.peak /sys/fs/cgroup/memory.max'"

  title "расчёты переключаются на хранилище в кластере"
  run cat k8s/22-s3-inside.yaml
  run kubectl apply -f k8s/22-s3-inside.yaml || return 1
  run docker stop "$OUTSIDE"
  run kubectl apply -f k8s/23-s3-client.yaml || return 1
  run kubectl -n "$S3NS" rollout status deployment/s3-client --timeout=120s || return 1
  run kubectl -n "$S3NS" exec deploy/s3-client -- python -m lab.kube ls
  run kubectl -n "$S3NS" get pods -o wide
}

clear 2>/dev/null
rm -rf logs/02_storage
mkdir -p logs/02_storage
capture 02_storage body
