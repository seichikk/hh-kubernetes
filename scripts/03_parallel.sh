#!/bin/bash
source "$(dirname "$0")/common.sh"
need_cluster

body() {
  clean_jobs
  title "план: 12 частей с границами по концам записей"
  run cat k8s/30-split.yaml
  run kubectl apply -f k8s/30-split.yaml || return 1
  finished pairs-split || { k logs job/pairs-split | tail -n 20; return 1; }
  run kubectl -n "$NS" logs job/pairs-split
  keep pairs-split 03_parallel

  title "замер пика памяти одной части: предел 1Gi"
  sed 's/name: pairs-map/name: pairs-map-probe/; s/memory: [0-9]*Mi/memory: 1Gi/' k8s/31-map.yaml > "$OUT/tmp.yaml"
  printf '\n$ sed "s/name: pairs-map/name: pairs-map-probe/; s/memory: [0-9]*Mi/memory: 1Gi/" k8s/31-map.yaml | kubectl apply -f -\n'
  kubectl apply -f "$OUT/tmp.yaml" || return 1
  rm -f "$OUT/tmp.yaml"
  finished pairs-map-probe || { k get pods; return 1; }
  keep pairs-map-probe 03_parallel
  sh_run "grep -h -E '^(часть|память)' logs/03_parallel/pairs-map-probe-*.log | sed 's/, узел.*//; s/ ([0-9]* байт)//' | paste - - | sort -t' ' -k2 -n"
  max=$(sed -n 's/^память контейнера: пик \([0-9]*\) миб.*/\1/p' logs/03_parallel/pairs-map-probe-*.log | sort -n | tail -n 1)
  min=$(sed -n 's/^память контейнера: пик \([0-9]*\) миб.*/\1/p' logs/03_parallel/pairs-map-probe-*.log | sort -n | head -n 1)
  limit=$(limit_for "$max")
  note ""
  note "пик по частям: от $min до $max миб; предел = $max * 1.25 с округлением вверх до 64 миб = $limit миб"
  set_memory "$limit" k8s/31-map.yaml k8s/40-map-all.yaml k8s/51-map-low.yaml
  k delete job pairs-map-probe >/dev/null

  title "расчёт параллельными задачами: 12 частей, по 6 подов одновременно"
  run cat k8s/31-map.yaml
  s3_mem_start logs/03_parallel/rustfs-mem.txt
  watch_pods logs/03_parallel/watch.log
  run kubectl apply -f k8s/31-map.yaml || return 1
  sleep 6
  run kubectl -n "$NS" get pods -o wide
  finished pairs-map || { k get pods; stop_watch; return 1; }
  stop_watch
  s3_mem_stop
  run kubectl -n "$NS" get job pairs-map -o wide
  run kubectl -n "$NS" get pods -o wide
  keep pairs-map 03_parallel
  sh_run "grep -h -E '^(часть|память)' logs/03_parallel/pairs-map-[0-9]*.log | sed 's/: байты.*, узел/ на/; s/ ([0-9]* байт)//' | paste - - | sort -t' ' -k2 -n"
  sh_run "python3 scripts/timeline.py logs/03_parallel/watch.log parallel"

  title "reduce: слияние частей и сверка с дз-3"
  run cat k8s/32-reduce.yaml
  run kubectl apply -f k8s/32-reduce.yaml || return 1
  finished pairs-reduce || { k logs job/pairs-reduce | tail -n 20; return 1; }
  run kubectl -n "$NS" logs job/pairs-reduce
  keep pairs-reduce 03_parallel

  title "результат на компьютере и сравнение с файлами дз-3"
  mkdir -p results/k8s results/hw3
  for f in k1.csv k2.csv k3.csv summary.json; do
    kubectl -n "$S3NS" exec deploy/s3-client -- python -m lab.kube cat "results/k8s-parts/$f" > "results/k8s/$f" || return 1
  done
  cp "$HW3"/results/mapreduce/k[123].csv results/hw3/
  sh_run "shasum -a 256 results/hw3/k*.csv results/k8s/k*.csv"
  sh_run "head -n 11 results/k8s/k2.csv"
  sh_run "diff <(head -n 11 results/hw3/k2.csv) <(head -n 11 results/k8s/k2.csv) && echo 'топ-10 пар: отличий нет'"
  sh_run "cmp results/hw3/k1.csv results/k8s/k1.csv && cmp results/hw3/k2.csv results/k8s/k2.csv && cmp results/hw3/k3.csv results/k8s/k3.csv && echo 'k1, k2, k3: файлы совпадают побайтно'"
  head -n 11 results/k8s/k2.csv | tail -n 10 | awk -F, '{ printf "%d & %s & %s & %s \\\\\n", NR, $1, $2, $3 }' | sed 's/#/\\#/g' > "$OUT/top10.tex"
  vars parallel-mem mapPeakMin "$min" mapPeakMax "$max" mapLimit "$limit"
}

clear 2>/dev/null
rm -rf logs/03_parallel
mkdir -p logs/03_parallel
capture 03_parallel body
