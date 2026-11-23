#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
VERILATOR=${VERILATOR:-verilator}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
ulimit -c 0 || :
python3 - "$ROOT/experiments/tile_fabric/memory_tiles.v" "$tmp/mutant.v" "$tmp/response_mutant.v" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
old = "next_priority[0] ? 2'b10 : 2'b01"
assert source.count(old) == 1
Path(sys.argv[2]).write_text(source.replace(old, "1'b0 ? 2'b10 : 2'b01"))
old = 'valid0 <= grant0 & ~we;'
assert source.count(old) == 1
Path(sys.argv[3]).write_text(source.replace(old, "valid0 <= 2'b00;"))
PY
build_and_run() {
  variant=$1
  source=$2
  "$VERILATOR" --binary --timing --assert -Wno-fatal -DFUNCTIONAL \
    --top-module memory_assertion_mutation_tb --Mdir "$tmp/$variant" \
    "$ROOT/experiments/tile_fabric/memory_assertion_mutation_tb.sv" \
    "$ROOT/experiments/tile_fabric/memory_contract_assertions.sv" "$source" \
    "$ROOT/src/program_memory.v" \
    "$ROOT/test/models/RM_IHPSG13_1P_core_behavioral_bm_bist.v" \
    "$ROOT/test/models/RM_IHPSG13_1P_1024x8_c2_bm_bist.v" \
    -MAKEFLAGS -j1 > "$tmp/$variant-build.log" 2>&1
  "$tmp/$variant/Vmemory_assertion_mutation_tb" > "$tmp/$variant-run.log" 2>&1
}
build_and_run reference "$ROOT/experiments/tile_fabric/memory_tiles.v"
if build_and_run mutant "$tmp/mutant.v"; then
  echo 'FAIL: fairness mutation was not detected' >&2; exit 1
fi
if ! grep -q 'a_fair_0' "$tmp/mutant-run.log"; then
  cat "$tmp/mutant-run.log" >&2
  echo 'FAIL: mutation did not fail the expected fairness assertion' >&2; exit 1
fi
echo 'PASS: fairness SVA rejects deliberately starved requester'
if build_and_run response_mutant "$tmp/response_mutant.v"; then
  echo 'FAIL: missing read response was not detected' >&2; exit 1
fi
if ! grep -q 'a_read_response' "$tmp/response_mutant-run.log"; then
  cat "$tmp/response_mutant-run.log" >&2
  echo 'FAIL: mutation did not fail the expected response assertion' >&2; exit 1
fi
echo 'PASS: response SVA rejects deliberately dropped reads'
