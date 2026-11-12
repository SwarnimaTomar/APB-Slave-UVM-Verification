// Plain-SystemVerilog (no UVM) twin of the UVM testbench.
// Same DUT, same interface/assertions, same constraints, same model.
// Purpose: lets Verilator (which cannot run UVM quickly) check the DUT,
// the SVA assertions and the bug-catching logic.
`timescale 1ns/1ps
module tb_plain;
    logic pclk = 0;
    always #5 pclk = ~pclk;
    apb_if vif (pclk);
    apb_slave dut (.pclk, .presetn(vif.presetn), .psel(vif.psel), .penable(vif.penable),
        .pwrite(vif.pwrite), .paddr(vif.paddr), .pwdata(vif.pwdata),
        .prdata(vif.prdata), .pready(vif.pready), .pslverr(vif.pslverr));

    class item;
        rand bit is_reset, write; rand bit [7:0] addr; rand bit [31:0] data;
        constraint c_reset { is_reset dist {0 := 97, 1 := 3}; }
        constraint c_dir   { write dist {1 := 50, 0 := 50}; }
        constraint c_addr  { addr dist { 8'h00:=15, 8'h04:=25, 8'h08:=15, 8'h0C:=25,
                                         [8'h01:8'h03]:/5, [8'h10:8'hFF]:/15 }; }
        constraint c_data  { data dist { 32'h0:=5, 32'hFFFF_FFFF:=5, [32'h1:32'hFFFF_FFFE]:/90 }; }
    endclass

    bit [31:0] m_ctrl, m_data, m_scratch; bit [7:0] m_count;
    int checks, errors, first_err_t = -1;
    int cov_ad[6][2]; int cov_w[4]; int cov_err[2]; int cov_reset;

    task automatic err(string s);
        errors++; if (first_err_t < 0) first_err_t = $time;
        if (errors <= 3) $display("  SCB ERROR @%0t: %s", $time, s);
    endtask

    task automatic do_reset();
        @(posedge pclk); #1; vif.psel <= 0; vif.penable <= 0; vif.presetn <= 0;
        repeat (2) @(posedge pclk); #1; vif.presetn <= 1;
        m_ctrl = 0; m_data = 0; m_scratch = 0; m_count = 0; cov_reset++;
    endtask

    task automatic xfer(bit wr, bit [7:0] a, bit [31:0] d);
        int waits = 0; bit valid, exp_err; bit [31:0] exp_r; int exp_w; int ai;
        @(posedge pclk); #1; vif.psel <= 1; vif.penable <= 0; vif.pwrite <= wr; vif.paddr <= a; vif.pwdata <= d;
        @(posedge pclk); #1; vif.penable <= 1;
        forever begin @(negedge pclk); if (vif.pready === 1'b1) break; waits++; end   // sample mid-cycle: race free
        valid = (a==8'h00)||(a==8'h04)||(a==8'h08)||(a==8'h0C);
        exp_err = !valid || (wr && a==8'h08); exp_w = m_ctrl[1:0];
        checks += 2;
        if (vif.pslverr !== exp_err) err($sformatf("pslverr exp %0b got %0b addr=%02h wr=%0b", exp_err, vif.pslverr, a, wr));
        if (waits != exp_w)          err($sformatf("waits exp %0d got %0d addr=%02h wr=%0b ctrl=%08h", exp_w, waits, a, wr, m_ctrl));
        if (wr) begin
            if (!exp_err) begin
                case (a) 8'h00: m_ctrl=d; 8'h04: m_data=d; 8'h0C: m_scratch=d; endcase
                m_count++;
            end
        end else if (valid) begin
            case (a) 8'h00: exp_r=m_ctrl; 8'h04: exp_r=m_data; 8'h08: exp_r={24'h0,m_count}; default: exp_r=m_scratch; endcase
            checks++;
            if (vif.prdata !== exp_r) err($sformatf("rdata exp %08h got %08h addr=%02h", exp_r, vif.prdata, a));
        end
        ai = (a==0)?0:(a==4)?1:(a==8)?2:(a==12)?3:(a<=3)?4:5;
        cov_ad[ai][wr]++; cov_w[waits<4?waits:3]++; cov_err[exp_err]++;
        @(posedge pclk); #1; vif.psel <= 0; vif.penable <= 0;
    endtask

    task automatic directed();
        xfer(0,8'h00,0); xfer(0,8'h04,0); xfer(0,8'h08,0); xfer(0,8'h0C,0);
        xfer(1,8'h04,32'hDEADBEEF); xfer(0,8'h04,0);
        xfer(1,8'h0C,32'h12345678); xfer(0,8'h0C,0);
        xfer(0,8'h08,0);
        xfer(1,8'h08,32'hFFFFFFFF); xfer(0,8'h08,0);
        xfer(1,8'h40,1); xfer(0,8'h40,0); xfer(0,8'h02,0);
        xfer(1,8'h00,0); xfer(0,8'h04,0);
        xfer(1,8'h00,1); xfer(0,8'h04,0);
        xfer(1,8'h00,2); xfer(0,8'h04,0);
        xfer(1,8'h00,3); xfer(0,8'h04,0); xfer(1,8'h0C,32'hA5A5A5A5); xfer(0,8'h00,0);
        do_reset();
        xfer(0,8'h00,0); xfer(0,8'h04,0); xfer(0,8'h08,0); xfer(0,8'h0C,0);
        xfer(1,8'h0C,32'hCAFEF00D); do_reset(); xfer(0,8'h0C,0);
    endtask

    initial begin
        item t = new();
        int holes = 0;
        vif.psel=0; vif.penable=0; vif.pwrite=0; vif.paddr=0; vif.pwdata=0; vif.presetn=0;
        repeat (3) @(posedge pclk); #1; vif.presetn <= 1;
        m_ctrl=0; m_data=0; m_scratch=0; m_count=0;
        #50;
        directed();
        repeat (3000) begin
            if (!t.randomize()) $fatal(1, "randomize failed");
            if (t.is_reset) do_reset(); else xfer(t.write, t.addr, t.data);
        end
        repeat (5) @(posedge pclk);
        $display("SCOREBOARD: %0d checks, %0d errors (first at %0d ns)", checks, errors, first_err_t/1000);
        $display("SVA failures: %0d", vif.assert_fail_count);
        for (int i=0;i<6;i++) for (int j=0;j<2;j++) if (cov_ad[i][j]==0) holes++;
        for (int i=0;i<4;i++) if (cov_w[i]==0) holes++;
        $display("COVERAGE holes (addr x dir, waits): %0d  resets=%0d  err_hits=%0d", holes, cov_reset, cov_err[1]);
        if (errors==0 && vif.assert_fail_count==0) $display("RESULT: PASSED"); else $display("RESULT: FAILED");
        $finish;
    end
endmodule
