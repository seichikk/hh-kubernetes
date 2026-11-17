#!/bin/bash
source "$(dirname "$0")/common.sh"

kind delete cluster --name "$CLUSTER"
