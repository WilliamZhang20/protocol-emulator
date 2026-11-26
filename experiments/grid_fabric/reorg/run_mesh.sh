#!/usr/bin/env bash
# Compiled configurations on the mesh (FABRIC_REORG.md criterion 3).
# compiled/*.hex are written by the compiler (protocol-emulator-compiler
# circt_lab/fabric_map.py) from source, for the contract beside them;
# mesh parameters are taken from that contract.
# Usage: run_mesh.sh BUILD_DIR [--sweep]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../../.." && pwd)
bin=$root/.tools/oss-cad-suite/bin; out=$1; mkdir -p "$out"
contract=$here/compiled/mesh_3x3.json; hex=$here/compiled/i2c_target+uart_rx.3x3.hex
params=$(python3 - "$contract" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); n = c['rows'] * c['cols']
kinds = sum(c['kinds'][x['kind']]['code'] << (2 * i) for i, x in enumerate(c['cells']))
ctx4 = sum((x['contexts'] == 4) << i for i, x in enumerate(c['cells']))
print(f"-Pmesh_tb.ROWS={c['rows']} -Pmesh_tb.COLS={c['cols']} -Pmesh_tb.WORD_PORT={c['word_port']['cell']} "
      f"-Pmesh_tb.KINDS={2*n}'d{kinds} -Pmesh_tb.CTX4={n}'d{ctx4}")
PY
)
"$bin/iverilog" -g2012 -s mesh_tb $params -o "$out/mesh" "$here/mesh_tb.sv" "$here/mesh.v" "$here/ctx_switch.v" \
  "$here/io_tile.v" "$here/wnet.v" "$root/src/grid_timer.v" "$root/src/fabric_shifter.v" "$root/src/config_bank.v" \
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
# Recorded (245-point sweep: 215 pass, the hand-mapped slice's envelope).
expect pass 40 10 10; EXTRA=+UART expect pass 40 10 10; EXTRA=+UART expect pass 4 1 4
EXTRA=+UART expect pass 20 1 4; EXTRA=+UART expect fail 20 2 2; EXTRA=+UART expect fail 8 1 3
[[ $bad == 0 ]] && echo "compiled I2C target + UART on the mesh: nominal, boundaries and expected failures as recorded"
exit $bad
