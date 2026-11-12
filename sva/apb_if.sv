// =====================================================================
// apb_if.sv - APB interface (bundle of wires) + SVA protocol assertions
//
// An interface groups all the bus wires into one object, so the UVM
// driver and monitor can use them through a "virtual interface".
//
// The assertions below are always watching the bus. They are written
// from the APB rules and from the slave spec. A failed assertion prints
// "ASSERT FAIL: <name>" with the time.
//
// Each assertion has a "cover property" twin, so the report shows that
// the situation was really seen (an assertion that never starts proves
// nothing - this is called a vacuous pass).
// =====================================================================
`timescale 1ns/1ps
interface apb_if (input logic pclk);

    logic        presetn;
    logic        psel;
    logic        penable;
    logic        pwrite;
    logic [7:0]  paddr;
    logic [31:0] pwdata;
    logic [31:0] prdata;
    logic        pready;
    logic        pslverr;

    // counters for the end-of-test report
    int unsigned assert_fail_count = 0;

    wire in_access = psel && penable;
    wire xfer_done = psel && penable && pready;
    wire addr_ok   = (paddr == 8'h00) || (paddr == 8'h04) ||
                     (paddr == 8'h08) || (paddr == 8'h0C);

    // ---------------- generic APB protocol rules ----------------

    // 1. After the SETUP phase (psel=1, penable=0) the next cycle MUST be ACCESS.
    property p_setup_then_access;
        @(posedge pclk) disable iff (!presetn)
        (psel && !penable) |=> (psel && penable);
    endproperty
    a_setup_then_access: assert property (p_setup_then_access)
        else begin assert_fail_count++; $error("ASSERT FAIL: a_setup_then_access (setup not followed by access)"); end
    c_setup_then_access: cover property (p_setup_then_access);

    // 2. PENABLE is only allowed while PSEL is 1.
    property p_penable_needs_psel;
        @(posedge pclk) disable iff (!presetn)
        penable |-> psel;
    endproperty
    a_penable_needs_psel: assert property (p_penable_needs_psel)
        else begin assert_fail_count++; $error("ASSERT FAIL: a_penable_needs_psel"); end

    // 3. While the slave is not ready, the master must keep everything stable.
    property p_stable_while_wait;
        @(posedge pclk) disable iff (!presetn)
        (psel && penable && !pready) |=> (penable && $stable(paddr) && $stable(pwrite) && $stable(pwdata));
    endproperty
    a_stable_while_wait: assert property (p_stable_while_wait)
        else begin assert_fail_count++; $error("ASSERT FAIL: a_stable_while_wait (signals changed during wait)"); end
    c_wait_seen: cover property (@(posedge pclk) disable iff (!presetn) (psel && penable && !pready));

    // 4. When a transfer finishes, PENABLE must drop in the next cycle.
    property p_penable_drops;
        @(posedge pclk) disable iff (!presetn)
        (psel && penable && pready) |=> !penable;
    endproperty
    a_penable_drops: assert property (p_penable_drops)
        else begin assert_fail_count++; $error("ASSERT FAIL: a_penable_drops"); end

    // 5. No X/Z on the control signals once reset is released.
    property p_no_x_control;
        @(posedge pclk) disable iff (!presetn)
        !$isunknown({psel, penable, pwrite, paddr});
    endproperty
    a_no_x_control: assert property (p_no_x_control)
        else begin assert_fail_count++; $error("ASSERT FAIL: a_no_x_control"); end

    // ---------------- slave (DUT) specific rules ----------------

    // 6. PSLVERR may only be 1 in the last cycle of a transfer.
    property p_err_only_at_end;
        @(posedge pclk) disable iff (!presetn)
        pslverr |-> xfer_done;
    endproperty
    a_err_only_at_end: assert property (p_err_only_at_end)
        else begin assert_fail_count++; $error("ASSERT FAIL: a_err_only_at_end"); end

    // 7. Access to an address that does not exist MUST give PSLVERR.
    property p_bad_addr_err;
        @(posedge pclk) disable iff (!presetn)
        (xfer_done && !addr_ok) |-> pslverr;
    endproperty
    a_bad_addr_err: assert property (p_bad_addr_err)
        else begin assert_fail_count++; $error("ASSERT FAIL: a_bad_addr_err (bad address, no PSLVERR)"); end
    c_bad_addr: cover property (@(posedge pclk) disable iff (!presetn) (xfer_done && !addr_ok));

    // 8. Writing the read-only STATUS register MUST give PSLVERR.
    property p_ro_write_err;
        @(posedge pclk) disable iff (!presetn)
        (xfer_done && pwrite && paddr == 8'h08) |-> pslverr;
    endproperty
    a_ro_write_err: assert property (p_ro_write_err)
        else begin assert_fail_count++; $error("ASSERT FAIL: a_ro_write_err (write to read-only register, no PSLVERR)"); end
    c_ro_write: cover property (@(posedge pclk) disable iff (!presetn) (xfer_done && pwrite && paddr == 8'h08));

    // 9. A normal access to a valid, writable/readable address must NOT give PSLVERR.
    property p_good_no_err;
        @(posedge pclk) disable iff (!presetn)
        (xfer_done && addr_ok && !(pwrite && paddr == 8'h08)) |-> !pslverr;
    endproperty
    a_good_no_err: assert property (p_good_no_err)
        else begin assert_fail_count++; $error("ASSERT FAIL: a_good_no_err (false error)"); end

    // 10. The slave may insert at most 3 wait cycles (CTRL[1:0] max is 3).
    property p_max_wait;
        @(posedge pclk) disable iff (!presetn)
        $rose(penable) |-> ##[0:3] pready;
    endproperty
    a_max_wait: assert property (p_max_wait)
        else begin assert_fail_count++; $error("ASSERT FAIL: a_max_wait (slave too slow)"); end

    // 11. Reset: when reset is active, registers read back as 0 afterwards
    //     (checked by the scoreboard, see apb_pkg.sv).

    // 12. PREADY, PSLVERR must not be X at the end of a transfer.
    property p_no_x_response;
        @(posedge pclk) disable iff (!presetn)
        xfer_done |-> !$isunknown({pslverr, prdata});
    endproperty
    a_no_x_response: assert property (p_no_x_response)
        else begin assert_fail_count++; $error("ASSERT FAIL: a_no_x_response"); end

endinterface
