#!/usr/bin/env bash
# I2C target slice on contexted switches (FABRIC_REORG.md promotion
# criterion 1). Usage: run_slice.sh BUILD_DIR [--sweep]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../../.." && pwd)
bin=$root/.tools/oss-cad-suite/bin; out=$1; mkdir -p "$out"
"$bin/iverilog" -g2012 -o "$out/slice" "$here/slice_i2c_tb.sv" "$here/ctx_switch.v" "$here/io_tile.v" \
  "$here/wnet.v" "$root/src/fabric_shifter.v" "$root/src/config_bank.v" 2> >(grep -v 'timescale\|inherit' >&2)
run() { timeout 60 "$bin/vvp" -N "$out/slice" +HALF=$1 +SETUP=$2 +HOLD=$3 | grep -q '^PASS'; }
if [[ ${2:-} == --sweep ]]; then
  p=0; f=0
  for h in 4 6 8 12 20; do for s in 1 2 3 4 5 6 8; do for d in 1 2 3 4 5 6 8; do
    if run $h $s $d; then p=$((p+1)); else f=$((f+1)); fi
  done; done; done
  echo "slice sweep: pass=$p fail=$f"; exit 0
fi
bad=0
expect() { local want=$1; shift; if run "$@"; then got=pass; else got=fail; fi
  [[ $got == "$want" ]] || { echo "UNEXPECTED $got (want $want): HALF=$1 SETUP=$2 HOLD=$3"; bad=1; }; }
# Recorded: passes whenever SCL is low for 5+ clocks (down to 4 high and a
# 1-clock SDA setup); fails at 4 low (the ACK is driven about 5 clocks
# after the SCL fall).
expect pass 40 10 10; expect pass 4 1 4; expect pass 4 4 1; expect pass 20 1 4; expect pass 8 3 2
expect fail 20 2 2; expect fail 8 1 3; expect fail 20 3 1
[[ $bad == 0 ]] && echo "I2C slice (contexted switches, real shifter, word network): nominal, boundaries and expected failures as recorded"
exit $bad
