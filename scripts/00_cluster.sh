#!/bin/bash
source "$(dirname "$0")/common.sh"

body() {
  title "кластер kind: control-plane и два рабочих узла"
  run kind version
  run cat k8s/kind.yaml
  if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    run kind create cluster --config k8s/kind.yaml || return 1
  fi
  kubectl config use-context "kind-$CLUSTER" >/dev/null
  run kubectl wait --for=condition=Ready nodes --all --timeout=180s || return 1
  run kubectl version
  run kubectl get nodes -o wide
  run kubectl get nodes -o custom-columns='NAME:.metadata.name,CPU:.status.capacity.cpu,MEMORY:.status.capacity.memory,ALLOC-CPU:.status.allocatable.cpu,ALLOC-MEMORY:.status.allocatable.memory'
  sh_run "kubectl describe node hh-worker | sed -n '/^Capacity:/,/^System Info:/p'"

  title "metrics-server для kubectl top"
  run kubectl apply -f "$METRICS" || return 1
  kubectl -n kube-system get deployment metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q insecure ||
    run kubectl -n kube-system patch deployment metrics-server --type=json \
      -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
  run kubectl -n kube-system rollout status deployment/metrics-server --timeout=240s || return 1

  title "образ с расчётом из дз-3"
  run cat docker/Dockerfile
  run docker build -q -f docker/Dockerfile -t "$IMG" . || return 1
  run docker images "$IMG"
  run kind load docker-image "$IMG" --name "$CLUSTER" || return 1
  sh_run "docker exec hh-worker crictl images | grep -E 'IMAGE|hh-k8s'"

  title "пространства имён"
  run kubectl apply -f k8s/00-namespaces.yaml || return 1
  run kubectl get pods -A -o wide
  for _ in $(seq 1 60); do
    kubectl top nodes >/dev/null 2>&1 && break
    sleep 2
  done
  run kubectl top nodes
}

clear 2>/dev/null
capture 00_cluster body
