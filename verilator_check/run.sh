#!/bin/bash
# Verilator check of DUT + SVA + stimulus (no UVM). Runs correct + each bug.
cd "$(dirname "$0")"
VROOT=$(python3 -c "import verilator,os;print(os.path.dirname(verilator.__file__))" 2>/dev/null)
export VERILATOR_ROOT="$VROOT"; V="$VROOT/bin/verilator"
run () { d=obj_$1; rm -rf $d
  $V --binary --timing --assert -CFLAGS -fcoroutines -Wno-fatal -Wno-lint -Wno-style -Wno-COVERIGN -Wno-TIMESCALEMOD \
     --top-module tb_plain -Mdir $d $2 ../rtl/apb_slave.sv ../sva/apb_if.sv tb_plain.sv > build_$1.log 2>&1 \
     || { echo "BUILD FAILED $1"; return; }
  ./$d/Vtb_plain > log_$1.txt 2>&1; rm -rf $d; }
run correct "" &
run BUG_PREADY_EARLY -DBUG_PREADY_EARLY &
wait
run BUG_NO_ERR_BAD_ADDR -DBUG_NO_ERR_BAD_ADDR &
run BUG_NO_ERR_RO_WRITE -DBUG_NO_ERR_RO_WRITE &
wait
run BUG_READ_WRONG -DBUG_READ_WRONG &
run BUG_WRITE_IN_SETUP -DBUG_WRITE_IN_SETUP &
wait
run BUG_RESET_SCRATCH -DBUG_RESET_SCRATCH &
wait
for v in correct BUG_PREADY_EARLY BUG_NO_ERR_BAD_ADDR BUG_NO_ERR_RO_WRITE BUG_READ_WRONG BUG_WRITE_IN_SETUP BUG_RESET_SCRATCH; do
  echo "== $v"; grep -E "SCOREBOARD:|SVA failures|COVERAGE|RESULT" log_$v.txt; grep -m2 "ASSERT FAIL" log_$v.txt | sed 's/^/   /'
done
