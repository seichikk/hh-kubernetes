#!/bin/bash
source "$(dirname "$0")/common.sh"

python3 - <<'PY' || exit 1
import ast
from pathlib import Path

src = Path("lab/kube.py").read_text()
tree = ast.parse(src)
for node in tree.body:
    if isinstance(node, ast.FunctionDef) and node.name in ("resources", "boundary", "split", "map_part", "on_term"):
        Path(f"report/out/code_{node.name}.txt").write_text(ast.get_source_segment(src, node) + "\n")
PY

PDFLATEX=$(type -P pdflatex || echo /Library/TeX/texbin/pdflatex)
cd report || exit 1
for i in 1 2; do
  "$PDFLATEX" -interaction=nonstopmode -halt-on-error report.tex >/dev/null 2>&1 || {
    grep -A5 '^!' report.log | head -20
    exit 1
  }
done
ls -lh report.pdf
