# UVM Verilator DIDNOTCONVERGE Debug Report (2026-03-11)

## 1. Objective
- Bring up `dv/uvm` verification on Verilator for `fa_attention_ip_top`.
- Eliminate startup `%Error-DIDNOTCONVERGE` at time 0.
- Preserve incremental build artifacts (no full clean of UVM library objects).

## 2. Current UVM Architecture (Implemented)
- Top: `dv/uvm/tb/top/fa_attention_ip_top_tb.sv`
- Agents:
  - AXI-Lite control: `dv/uvm/agents/axil/*`
  - AXI memory model: `dv/uvm/agents/axi_mem/*`
- Env: `dv/uvm/env/*`
- Reg model: `dv/uvm/regmodel/*`
- Sequences/tests: `dv/uvm/seq/*`, `dv/uvm/tests/*`
- Sim flow: `dv/uvm/sim/Makefile`

## 3. Root-Cause Analysis Timeline

### Phase A: Driver-side NBA loop (fixed)
- Symptom: `NBA region did not converge` at time 0.
- Evidence in generated C++:
  - `__VnbaEventTrigger = 1U` repeatedly generated from UVM class driver code.
  - Coroutines waiting on `__VnbaEvent` were re-triggering each other without time advancing.
- Cause:
  - Non-blocking assignments (`<=`) were used in class-based driver tasks/functions when driving VIF signals.
- Fix applied:
  - Convert VIF assignments to blocking (`=`) in:
    - `dv/uvm/agents/axi_mem/fa_axi_mem_driver.sv`
    - `dv/uvm/agents/axil/fa_axil_driver.sv`

### Phase B: UVM wait_for_nba_region behavior (partial workaround)
- Remaining trigger source moved to UVM infrastructure (`uvm_wait_for_nba_region`) in `uvm_globals.svh`.
- External evidence checked:
  - Verilator issue `#7137` (NBA DIDNOTCONVERGE, scheduling bug family)
  - Verilator issue `#7068` (related event-trigger regression/fixes)
- Minimal validation setup created:
  - `dv/uvm/tests/minimal/minimal_tb.sv`
  - Reproduced convergence problem with stock mechanism.
- Local workaround applied in UVM lib:
  - `dv/uvm/lib/uvm-verilator/src/base/uvm_globals.svh`
  - `uvm_wait_for_nba_region` uses `#1step` under `` `ifdef VERILATOR ``.
- Result:
  - Minimal test now passes and exits cleanly.

## 4. Full DUT Status
- Command: `make -C dv/uvm/sim smoke BUILD_JOBS=8`
- Status: still fails with
  - `%Error-DIDNOTCONVERGE ... NBA region did not converge after '--converge-limit' of 100 tries`
- Interpretation:
  - Driver-side NBA loop is fixed.
  - UVM base wait-for-NBA path is mitigated for minimal case.
  - Remaining non-convergence appears tied to full DUT + full UVM interaction path (scheduling issue still present in this configuration).

## 5. Non-destructive Build Handling
- To force re-verilation without full clean:
  - Remove only `Vfa_attention_ip_top_tb__verFiles.dat` under build dir.
- This preserves heavy prebuilt artifacts while forcing changed SV/UVM sources to be recompiled.

## 6. Recommended Next Steps
1. Build smallest reproducer from current full setup that still fails:
   - Keep UVM env, replace DUT with reduced shell modules stage-by-stage.
2. Bisect failing RTL hierarchy:
   - Start from `fa_attention_ip_top` shell, then re-enable `u_core`, `u_dma_rd`, `u_dma_wr` incrementally.
3. Once minimized, submit upstream Verilator reproducer linked to `#7137`.
4. Keep current local workaround (`#1step`) for productivity until upstream fix lands.

## 7. Files Changed in This Debug Round
- `dv/uvm/agents/axi_mem/fa_axi_mem_driver.sv`
- `dv/uvm/agents/axil/fa_axil_driver.sv`
- `dv/uvm/lib/uvm-verilator/src/base/uvm_globals.svh`
- `dv/uvm/sim/Makefile`
- `dv/uvm/tests/minimal/minimal_tb.sv`
