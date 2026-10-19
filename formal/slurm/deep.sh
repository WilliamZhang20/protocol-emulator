#!/bin/bash
# Long formal runs on a Slurm cluster: the protocol proofs and the
# wrong-program check, for bounds or solvers that outgrow CI and a login
# node (1 h CPU limit).
#
# usage (from the repository root, on a login node):
#   formal/slurm/deep.sh            # snapshot the tree and submit
#   ACCOUNT=def-foo TIME=12:00:00 formal/slurm/deep.sh
#
# The job runs on a copy of the working tree in $SCRATCH (home may be
# read-only on compute nodes, and the copy lets the tree change meanwhile).
# Results: $SCRATCH/protocol-emulator-formal/<stamp>/{slurm.log,build/}.
#
# Each protocol proof runs three solvers at once (sby starts every engine
# and takes the first answer); the checked-in .sby files use boolector only.
set -euo pipefail

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
STAMP=$(date +%Y%m%d-%H%M%S)-$(git -C "$ROOT" rev-parse --short HEAD)
RUN=${SCRATCH:?SCRATCH not set}/protocol-emulator-formal/$STAMP
ACCOUNT=${ACCOUNT:-def-yashpant}
TIME=${TIME:-12:00:00}

mkdir -p "$RUN"
for copy in deep negative; do
  rsync -a --exclude .git --exclude build --exclude .tools --exclude .venv \
    --exclude 'formal/protocols/*_rom.vh' --exclude 'formal/protocols/*_prearm.ys' \
    "$ROOT/" "$RUN/$copy/"
done
sed -i 's/^smtbmc [a-z]*$/smtbmc yices\nsmtbmc bitwuzla\nsmtbmc boolector/' \
  "$RUN"/deep/formal/protocols/*.sby

TOOLS=$ROOT/.tools/oss-cad-suite/bin
VENV=$ROOT/.venv/bin
sbatch --account="$ACCOUNT" --time="$TIME" --nodes=1 --ntasks=1 --job-name=pe-formal-deep \
  --output="$RUN/slurm.log" --chdir="$RUN" <<EOF
#!/bin/bash
set -uo pipefail
ulimit -t unlimited 2>/dev/null || true
export PATH=$TOOLS:$VENV:\$PATH
make -C deep/formal uart_tx ws2812 spi_master EDA_BIN=$TOOLS PYTHON=$VENV/python \
  BUILD_DIR=$RUN/build/deep > deep.log 2>&1 &
deep=\$!
make -C negative/formal protocol-negative EDA_BIN=$TOOLS PYTHON=$VENV/python \
  BUILD_DIR=$RUN/build/negative > negative.log 2>&1 &
negative=\$!
wait \$deep;     echo "protocol proofs: exit \$?"
wait \$negative; echo "protocol-negative: exit \$?"
grep -h 'rejected\|NOT REJECTED' negative.log
grep -h 'DONE' deep.log
EOF
echo "run dir: $RUN"
