#!/usr/bin/env bash
# Two-event sequencer prototype with the I2C target (FABRIC_REORG.md step 2).
# Usage: run_seq2.sh BUILD_DIR [--sweep]
# Default: checks the recorded results at their boundaries, including the
# cases that must fail (so the test can fail). --sweep: the full 245-point
# timing sweep for all four variants.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
bin=$(cd "$here/../../.." && pwd)/.tools/oss-cad-suite/bin
out=$1; mkdir -p "$out"
for q in 0 1; do for l in 0 1; do
  "$bin/iverilog" -g2012 -s tb -s trace -P tb.QUAL=$q -P tb.LATCH=$l -o "$out/seq2_q${q}_$l" \
    "$here/seq2_i2c_target_tb.sv" "$here/seq2.v" 2> >(grep -v timescale >&2)
done; done
run() { timeout 60 "$bin/vvp" -N "$out/seq2_q$1_$2" +HALF=$3 +SETUP=$4 +HOLD=$5 | grep -q '^PASS'; }
if [[ ${2:-} == --sweep ]]; then
  for q in 0 1; do for l in 0 1; do p=0; f=0
    for h in 4 6 8 12 20; do for s in 1 2 3 4 5 6 8; do for d in 1 2 3 4 5 6 8; do
      if run $q $l $h $s $d; then p=$((p+1)); else f=$((f+1)); fi
    done; done; done
    echo "QUAL=$q LATCH=$l pass=$p fail=$f"
  done; done
  exit 0
fi
bad=0
expect() {   # expect pass|fail QUAL LATCH HALF SETUP HOLD
  local want=$1; shift
  if run "$@"; then got=pass; else got=fail; fi
  [[ $got == "$want" ]] || { echo "UNEXPECTED $got (want $want): QUAL=$1 LATCH=$2 HALF=$3 SETUP=$4 HOLD=$5"; bad=1; }
}
for l in 0 1; do
  expect pass 0 $l 40 10 10; expect pass 1 $l 40 10 10
  # Program B (LUT4 START/STOP): passes whenever SCL is low for 5+ clocks,
  # down to 4 clocks high; fails at 4 low (the ACK cannot be driven in time).
  expect pass 1 $l 4 1 4; expect pass 1 $l 4 4 1; expect pass 1 $l 20 3 2
  expect fail 1 $l 20 2 2; expect fail 1 $l 8 1 3
  # Program A (the lane program's shape): an SDA change within 2 clocks of
  # the SCL rise is taken for START/STOP.
  expect fail 0 $l 20 2 8; expect pass 0 $l 20 3 8
done
[[ $bad == 0 ]] && echo "seq2 I2C target: nominal, boundaries and expected failures as recorded (both event modes)"
exit $bad
