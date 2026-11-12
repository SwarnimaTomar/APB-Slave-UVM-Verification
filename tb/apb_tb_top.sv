// =====================================================================
// apb_tb_top.sv - top module: clock, DUT, interface, starts UVM
// =====================================================================
`timescale 1ns/1ps

module apb_tb_top;
    import uvm_pkg::*;
    import apb_pkg::*;

    logic pclk = 0;
    always #5 pclk = ~pclk;                 // 100 MHz clock

    apb_if vif (pclk);                      // the bundle of APB wires (+ assertions)

    apb_slave dut (
        .pclk    (pclk),
        .presetn (vif.presetn),
        .psel    (vif.psel),
        .penable (vif.penable),
        .pwrite  (vif.pwrite),
        .paddr   (vif.paddr),
        .pwdata  (vif.pwdata),
        .prdata  (vif.prdata),
        .pready  (vif.pready),
        .pslverr (vif.pslverr)
    );

    initial begin
        // give the interface to every UVM component
        uvm_config_db #(virtual apb_if)::set(null, "*", "vif", vif);
        run_test("apb_rand_test");          // can be overridden: +UVM_TESTNAME=apb_directed_test
    end
endmodule
