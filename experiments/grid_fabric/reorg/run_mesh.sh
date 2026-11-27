#!/usr/bin/env bash
# Compiled configurations on the mesh (FABRIC_REORG.md criterion 3).
# compiled/*.hex are written by the compiler (protocol-emulator-compiler
# circt_lab/fabric_map.py) from source, for the contract beside them;
# mesh parameters are taken from that contract.
# Usage: run_mesh.sh BUILD_DIR [--sweep]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../../.." && pwd)
bin=$root/.tools/oss-cad-suite/bin; out=$1; mkdir -p "$out"
t=test_3x5c
contract=$here/compiled/$t.json; hex=$here/compiled/i2c_target+uart_rx.$t.hex
tx_hex=$here/compiled/uart_tx.$t.hex; crc_hex=$here/compiled/crc_tx.$t.hex
params=$(python3 - "$contract" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); n = c['rows'] * c['cols']
code = lambda x: 1 if x['kind'] == 'counter' else c['kinds'][x['kind']]['code']   # counters: CNT
kinds = sum(code(x) << (2 * i) for i, x in enumerate(c['cells']))
ctx4 = sum((x['contexts'] == 4) << i for i, x in enumerate(c['cells']))
cnt = sum((x['kind'] == 'counter') << i for i, x in enumerate(c['cells']))
print(f"-Pmesh_tb.ROWS={c['rows']} -Pmesh_tb.COLS={c['cols']} -Pmesh_tb.WORD_PORT={c['word_port']['cell']} "
      f"-Pmesh_tb.KINDS={2*n}'d{kinds} -Pmesh_tb.CTX4={n}'d{ctx4} -Pmesh_tb.CNT={n}'d{cnt}")
PY
)
"$bin/iverilog" -g2012 -s mesh_tb $params -o "$out/mesh" "$here/mesh_tb.sv" "$here/mesh.v" "$here/ctx_switch.v" \
  "$here/io_tile.v" "$here/wnet.v" "$root/src/grid_timer.v" "$root/src/fabric_shifter.v" "$root/src/fabric_crc.v" \
  "$root/src/config_bank.v" "$root/src/fabric_counter.v" \
  2> >(grep -v 'timescale\|inherit' >&2)
run() { timeout 60 "$bin/vvp" -N "$out/mesh" +CFG="$hex" +HALF=$1 +SETUP=$2 +HOLD=$3 ${EXTRA:-} | grep -q '^PASS'; }
if [[ ${2:-} == --sweep ]]; then
  p=0; f=0
  for h in 4 6 8 12 20; do for s in 1 2 3 4 5 6 8; do for o in 1 2 3 4 5 6 8; do
    if EXTRA=+UART run $h $s $o; then p=$((p+1)); else f=$((f+1)); fi
  done; done; done
  echo "compiled mesh sweep (I2C + UART): pass=$p fail=$f"; exit 0
fi
bad=0
expect() { local want=$1; shift; if run "$@"; then got=pass; else got=fail; fi
  [[ $got == "$want" ]] || { echo "UNEXPECTED $got (want $want): HALF=$1 SETUP=$2 HOLD=$3 ${EXTRA:-}"; bad=1; }; }
# Recorded on the test mesh (3 x 5 candidate); the sweep (--sweep) is to
# match the hand-mapped slice's 215 of 245.
expect pass 40 10 10; EXTRA=+UART expect pass 40 10 10; EXTRA=+UART expect pass 4 1 4
EXTRA=+UART expect pass 20 1 4; EXTRA=+UART expect fail 20 2 2; EXTRA=+UART expect fail 8 1 3
# Step 4 L0 (cell-side hardware): transmit from the reader on a push-pull
# pad; a burst with the linked CRC cell's CRC-16 tail on a complementary pad pair.
for t in "TX $tx_hex" "CRCTX $crc_hex"; do set -- $t
  timeout 60 "$bin/vvp" -N "$out/mesh" +CFG="$2" +$1 | grep -q '^PASS' || { echo "UNEXPECTED fail: +$1"; bad=1; }
done
[[ $bad == 0 ]] && echo "compiled designs on the mesh: I2C target + UART (nominal, boundaries, expected failures as recorded), UART TX from the reader, CRC tail on a pad pair"
exit $bad
