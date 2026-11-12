// =====================================================================
// apb_pkg.sv - the whole UVM testbench for the APB slave
//
// UVM = a standard way (a library of classes) to build testbenches.
// The pieces and what each one does:
//
//   apb_item        one bus transfer (address, data, read/write) = "transaction"
//   apb_sequence    makes a list of items (the test scenario)
//   apb_sequencer   hands items from the sequence to the driver
//   apb_driver      turns an item into real wiggling of the APB wires
//   apb_monitor     only WATCHES the wires, rebuilds items, sends copies to
//                   the scoreboard and the coverage collector
//   apb_scoreboard  has a model of the registers; compares DUT answer vs model
//   apb_coverage    functional coverage: counts which situations were tested
//   apb_agent       driver + sequencer + monitor in one box
//   apb_env         agent + scoreboard + coverage connected together
//   apb_*_test      picks the sequence and runs it
//
// Data flow:  sequence -> sequencer -> driver -> [DUT] -> monitor -> scoreboard/coverage
// =====================================================================
`timescale 1ns/1ps
package apb_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // =================================================================
    // 1. TRANSACTION: one APB transfer
    // =================================================================
    class apb_item extends uvm_sequence_item;

        // ---- randomized inputs ----
        rand bit        is_reset;   // 1 = this "item" is a reset pulse, not a transfer
        rand bit        write;      // 1 = write, 0 = read
        rand bit [7:0]  addr;
        rand bit [31:0] data;       // write data

        // ---- filled by the monitor (what the DUT answered) ----
        bit [31:0] rdata;
        bit        slverr;
        int        waits;           // wait cycles the slave inserted

        // CONSTRAINTS: rules for the random values (so random is not "pure junk")
        constraint c_reset { is_reset dist {0 := 97, 1 := 3}; }
        constraint c_dir   { write dist {1 := 50, 0 := 50}; }
        constraint c_addr  { addr dist {
                                8'h00         := 15,    // CTRL
                                8'h04         := 25,    // DATA
                                8'h08         := 15,    // STATUS (read-only)
                                8'h0C         := 25,    // SCRATCH
                                [8'h01:8'h03] :/ 2,     // not aligned -> invalid
                                [8'h05:8'h07] :/ 1,     // not aligned -> invalid
                                [8'h09:8'h0B] :/ 1,     // not aligned -> invalid
                                [8'h0D:8'h0F] :/ 1,     // not aligned -> invalid
                                [8'h10:8'hFF] :/ 15 }; }// outside the map -> invalid
        constraint c_data  { data dist { 32'h0 := 5, 32'hFFFF_FFFF := 5,
                                         [32'h1:32'hFFFF_FFFE] :/ 90 }; }

        `uvm_object_utils_begin(apb_item)
            `uvm_field_int(is_reset, UVM_ALL_ON)
            `uvm_field_int(write,    UVM_ALL_ON)
            `uvm_field_int(addr,     UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(data,     UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(rdata,    UVM_ALL_ON | UVM_HEX)
            `uvm_field_int(slverr,   UVM_ALL_ON)
        `uvm_object_utils_end

        function new(string name = "apb_item");
            super.new(name);
        endfunction

        function string convert2string();
            if (is_reset) return "RESET";
            return $sformatf("%s addr=0x%02h wdata=0x%08h | rdata=0x%08h slverr=%0b waits=%0d",
                             write ? "WR" : "RD", addr, data, rdata, slverr, waits);
        endfunction
    endclass

    // =================================================================
    // 2. SEQUENCER (just a standard UVM sequencer for apb_item)
    // =================================================================
    typedef uvm_sequencer #(apb_item) apb_sequencer;

    // =================================================================
    // 3. DRIVER: item -> pin wiggling
    // =================================================================
    class apb_driver extends uvm_driver #(apb_item);
        `uvm_component_utils(apb_driver)

        virtual apb_if vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual apb_if)::get(this, "", "vif", vif))
                `uvm_fatal("DRV", "no virtual interface was given to the driver")
        endfunction

        task run_phase(uvm_phase phase);
            // idle values
            vif.psel <= 0;  vif.penable <= 0;  vif.pwrite <= 0;
            vif.paddr <= 0; vif.pwdata <= 0;
            // initial reset
            vif.presetn <= 0;
            repeat (3) @(posedge vif.pclk);
            #1 vif.presetn <= 1;

            forever begin
                seq_item_port.get_next_item(req);   // ask the sequencer for an item
                if (req.is_reset) do_reset();
                else              do_transfer(req);
                seq_item_port.item_done();          // tell the sequencer we finished
            end
        endtask

        task do_reset();
            @(posedge vif.pclk); #1;        // drive 1 ns after the clock edge (avoids races)
            vif.psel <= 0; vif.penable <= 0;
            vif.presetn <= 0;
            repeat (2) @(posedge vif.pclk);
            #1 vif.presetn <= 1;
        endtask

        task do_transfer(apb_item t);
            // SETUP phase
            @(posedge vif.pclk); #1;        // drive 1 ns after the clock edge (avoids races)
            vif.psel   <= 1;
            vif.penable <= 0;
            vif.pwrite <= t.write;
            vif.paddr  <= t.addr;
            vif.pwdata <= t.data;
            // ACCESS phase
            @(posedge vif.pclk); #1;
            vif.penable <= 1;
            // wait until the slave says PREADY
            // (we look in the middle of the clock, at the falling edge, so we never
            //  race with the DUT which changes its outputs on the rising edge)
            do @(negedge vif.pclk); while (vif.pready !== 1'b1);
            @(posedge vif.pclk); #1;            // the cycle in which the transfer completes
            // transfer is over: go back to idle
            vif.psel    <= 0;
            vif.penable <= 0;
        endtask
    endclass

    // =================================================================
    // 4. MONITOR: only watches the wires
    // =================================================================
    class apb_monitor extends uvm_monitor;
        `uvm_component_utils(apb_monitor)

        virtual apb_if vif;
        uvm_analysis_port #(apb_item) ap;    // sends what it saw to whoever listens

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            ap = new("ap", this);
            if (!uvm_config_db #(virtual apb_if)::get(this, "", "vif", vif))
                `uvm_fatal("MON", "no virtual interface was given to the monitor")
        endfunction

        task run_phase(uvm_phase phase);
            int waits = 0;
            apb_item t;
            fork
                // watch for resets
                forever begin
                    @(negedge vif.presetn);
                    waits = 0;
                    t = apb_item::type_id::create("rst_item");
                    t.is_reset = 1;
                    ap.write(t);
                end
                // watch for transfers
                forever begin
                    @(negedge vif.pclk);        // sample mid-cycle: no race with the DUT
                    if (vif.presetn === 1'b1 && vif.psel === 1'b1 && vif.penable === 1'b1) begin
                        if (vif.pready === 1'b1) begin
                            t = apb_item::type_id::create("mon_item");
                            t.is_reset = 0;
                            t.write    = vif.pwrite;
                            t.addr     = vif.paddr;
                            t.data     = vif.pwdata;
                            t.rdata    = vif.prdata;
                            t.slverr   = vif.pslverr;
                            t.waits    = waits;
                            waits      = 0;
                            ap.write(t);
                        end else begin
                            waits++;
                        end
                    end
                end
            join
        endtask
    endclass

    // =================================================================
    // 5. SCOREBOARD: model of the registers + compare
    // =================================================================
    class apb_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(apb_scoreboard)

        uvm_analysis_imp #(apb_item, apb_scoreboard) imp;   // receives items from the monitor

        // the model: what the registers SHOULD contain
        bit [31:0] m_ctrl, m_data, m_scratch;
        bit [7:0]  m_count;
        int checks, errors;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            imp = new("imp", this);
        endfunction

        function void reset_model();
            m_ctrl = 0; m_data = 0; m_scratch = 0; m_count = 0;
        endfunction

        function void do_check(bit ok, string what, apb_item t);
            checks++;
            if (!ok) begin
                errors++;
                `uvm_error("SCB", $sformatf("%s  [%s]", what, t.convert2string()))
            end
        endfunction

        // called every time the monitor sees something
        function void write(apb_item t);
            bit valid_addr, exp_err;
            bit [31:0] exp_rdata;
            int exp_waits;

            if (t.is_reset) begin
                reset_model();
                return;
            end

            valid_addr = (t.addr == 8'h00) || (t.addr == 8'h04) ||
                         (t.addr == 8'h08) || (t.addr == 8'h0C);
            exp_err    = !valid_addr || (t.write && t.addr == 8'h08);
            exp_waits  = m_ctrl[1:0];       // wait cycles = CTRL[1:0] BEFORE this transfer

            do_check(t.slverr === exp_err,    $sformatf("PSLVERR expected %0b", exp_err), t);
            do_check(t.waits  === exp_waits,  $sformatf("wait cycles expected %0d", exp_waits), t);

            if (t.write) begin
                if (!exp_err) begin
                    case (t.addr)
                        8'h00: m_ctrl    = t.data;
                        8'h04: m_data    = t.data;
                        8'h0C: m_scratch = t.data;
                    endcase
                    m_count++;
                end
            end else if (valid_addr) begin
                case (t.addr)
                    8'h00: exp_rdata = m_ctrl;
                    8'h04: exp_rdata = m_data;
                    8'h08: exp_rdata = {24'h0, m_count};
                    8'h0C: exp_rdata = m_scratch;
                endcase
                do_check(t.rdata === exp_rdata, $sformatf("read data expected 0x%08h", exp_rdata), t);
            end
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SCB", $sformatf("SCOREBOARD: %0d checks, %0d errors", checks, errors), UVM_NONE)
        endfunction
    endclass

    // =================================================================
    // 6. FUNCTIONAL COVERAGE
    // Code coverage asks "was this line executed?".
    // Functional coverage asks "did we test the situations the SPEC cares about?".
    // =================================================================
    class apb_coverage extends uvm_subscriber #(apb_item);
        `uvm_component_utils(apb_coverage)

        apb_item it;

        covergroup cg;
            option.per_instance = 1;

            cp_addr: coverpoint it.addr {
                bins ctrl    = {8'h00};
                bins data    = {8'h04};
                bins status  = {8'h08};
                bins scratch = {8'h0C};
                bins unaligned = {[8'h01:8'h03], [8'h05:8'h07], [8'h09:8'h0B], [8'h0D:8'h0F]};
                bins outside   = {[8'h10:8'hFF]};
            }
            cp_dir: coverpoint it.write {
                bins read  = {0};
                bins write = {1};
            }
            cp_err: coverpoint it.slverr {
                bins ok    = {0};
                bins error = {1};
            }
            cp_waits: coverpoint it.waits {
                bins w0 = {0};
                bins w1 = {1};
                bins w2 = {2};
                bins w3 = {3};
            }
            cp_wdata: coverpoint it.data {
                bins zero = {32'h0};
                bins ones = {32'hFFFF_FFFF};
                bins other = default;
            }

            // CROSS: every register must be tried with BOTH read and write,
            // and the error response must be seen
            x_addr_dir: cross cp_addr, cp_dir;
            x_addr_err: cross cp_addr, cp_err {
                // impossible by spec: a bad address can never answer OK,
                // a valid RW address can never answer ERROR
                ignore_bins bad_addr_ok = binsof(cp_err.ok) &&
                                          (binsof(cp_addr.unaligned) || binsof(cp_addr.outside));
                ignore_bins good_addr_err = binsof(cp_err.error) &&
                                          (binsof(cp_addr.ctrl) || binsof(cp_addr.data) || binsof(cp_addr.scratch));
            }
            x_dir_waits: cross cp_dir, cp_waits;
        endgroup

        covergroup cg_reset;
            cp_reset_seen: coverpoint it.is_reset { bins reset_seen = {1}; }
        endgroup

        function new(string name, uvm_component parent);
            super.new(name, parent);
            cg       = new();
            cg_reset = new();
        endfunction

        // subscriber: called by the monitor for every item
        function void write(apb_item t);
            it = t;
            if (t.is_reset) cg_reset.sample();
            else            cg.sample();
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("COV", $sformatf("FUNCTIONAL COVERAGE: transfers %.1f%%, reset %.1f%%",
                       cg.get_inst_coverage(), cg_reset.get_inst_coverage()), UVM_NONE)
        endfunction
    endclass

    // =================================================================
    // 7. AGENT and ENVIRONMENT: just boxes that hold the parts
    // =================================================================
    class apb_agent extends uvm_agent;
        `uvm_component_utils(apb_agent)

        apb_driver    drv;
        apb_sequencer sqr;
        apb_monitor   mon;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            drv = apb_driver   ::type_id::create("drv", this);
            sqr = apb_sequencer::type_id::create("sqr", this);
            mon = apb_monitor  ::type_id::create("mon", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);   // driver <-> sequencer
        endfunction
    endclass

    class apb_env extends uvm_env;
        `uvm_component_utils(apb_env)

        apb_agent      agt;
        apb_scoreboard scb;
        apb_coverage   cov;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agt = apb_agent     ::type_id::create("agt", this);
            scb = apb_scoreboard::type_id::create("scb", this);
            cov = apb_coverage  ::type_id::create("cov", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            agt.mon.ap.connect(scb.imp);                 // monitor -> scoreboard
            agt.mon.ap.connect(cov.analysis_export);     // monitor -> coverage
        endfunction
    endclass

    // =================================================================
    // 8. SEQUENCES: the test scenarios
    // =================================================================

    // helper: one write or read, with fixed values
    class apb_one_seq extends uvm_sequence #(apb_item);
        `uvm_object_utils(apb_one_seq)
        bit        is_reset = 0;
        bit        write;
        bit [7:0]  addr;
        bit [31:0] data;
        function new(string name = "apb_one_seq");
            super.new(name);
        endfunction
        task body();
            apb_item t = apb_item::type_id::create("t");
            start_item(t);
            t.is_reset = is_reset;
            t.write    = write;
            t.addr     = addr;
            t.data     = data;
            finish_item(t);
        endtask
    endclass

    // DIRECTED sequence: fixed, hand-written scenarios
    class apb_directed_seq extends uvm_sequence #(apb_item);
        `uvm_object_utils(apb_directed_seq)
        function new(string name = "apb_directed_seq");
            super.new(name);
        endfunction

        task xfer(bit wr, bit [7:0] a, bit [31:0] d = 0);
            apb_one_seq s = apb_one_seq::type_id::create("s");
            s.write = wr; s.addr = a; s.data = d;
            s.start(m_sequencer);
        endtask

        task do_rst();
            apb_one_seq s = apb_one_seq::type_id::create("s");
            s.is_reset = 1;
            s.start(m_sequencer);
        endtask

        task body();
            // reset values: everything reads 0
            xfer(0, 8'h00); xfer(0, 8'h04); xfer(0, 8'h08); xfer(0, 8'h0C);
            // write then read each normal register
            xfer(1, 8'h04, 32'hDEAD_BEEF); xfer(0, 8'h04);
            xfer(1, 8'h0C, 32'h1234_5678); xfer(0, 8'h0C);
            // status counts successful writes
            xfer(0, 8'h08);
            // write to the read-only register -> error, value unchanged
            xfer(1, 8'h08, 32'hFFFF_FFFF); xfer(0, 8'h08);
            // bad addresses -> error
            xfer(1, 8'h40, 32'h1); xfer(0, 8'h40); xfer(0, 8'h02);
            // every wait setting (CTRL[1:0] = 0..3), one access after each
            xfer(1, 8'h00, 32'h0); xfer(0, 8'h04);
            xfer(1, 8'h00, 32'h1); xfer(0, 8'h04);
            xfer(1, 8'h00, 32'h2); xfer(0, 8'h04);
            xfer(1, 8'h00, 32'h3); xfer(0, 8'h04); xfer(1, 8'h0C, 32'hA5A5_A5A5);
            xfer(0, 8'h00);
            // reset must clear everything
            do_rst();
            xfer(0, 8'h00); xfer(0, 8'h04); xfer(0, 8'h08); xfer(0, 8'h0C);
            // reset after writing
            xfer(1, 8'h0C, 32'hCAFE_F00D);
            do_rst();
            xfer(0, 8'h0C);
        endtask
    endclass

    // RANDOM sequence: constrained-random items
    class apb_random_seq extends uvm_sequence #(apb_item);
        `uvm_object_utils(apb_random_seq)
        int unsigned count = 500;
        function new(string name = "apb_random_seq");
            super.new(name);
        endfunction
        task body();
            repeat (count) begin
                apb_item t = apb_item::type_id::create("t");
                start_item(t);
                if (!t.randomize()) `uvm_error("SEQ", "randomize failed")
                finish_item(t);
            end
        endtask
    endclass

    // =================================================================
    // 9. TESTS
    // =================================================================
    class apb_base_test extends uvm_test;
        `uvm_component_utils(apb_base_test)

        apb_env        env;
        virtual apb_if vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = apb_env::type_id::create("env", this);
            if (!uvm_config_db #(virtual apb_if)::get(this, "", "vif", vif))
                `uvm_fatal("TEST", "no virtual interface")
        endfunction

        // children override this to choose what to run
        virtual task run_sequences();
        endtask

        task run_phase(uvm_phase phase);
            phase.raise_objection(this);        // "I am still busy, do not end the simulation"
            #50;                                // let the initial reset finish
            run_sequences();
            #100;
            phase.drop_objection(this);         // "done"
        endtask

        function void report_phase(uvm_phase phase);
            uvm_report_server rs = uvm_report_server::get_server();
            int sva_fails = vif.assert_fail_count;
            `uvm_info("RESULT", $sformatf("SVA assertion failures: %0d", sva_fails), UVM_NONE)
            if (rs.get_severity_count(UVM_ERROR) == 0 && rs.get_severity_count(UVM_FATAL) == 0 && sva_fails == 0)
                `uvm_info("RESULT", "TEST PASSED", UVM_NONE)
            else
                `uvm_info("RESULT", "TEST FAILED", UVM_NONE)
        endfunction
    endclass

    class apb_directed_test extends apb_base_test;
        `uvm_component_utils(apb_directed_test)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        task run_sequences();
            apb_directed_seq s = apb_directed_seq::type_id::create("s");
            s.start(env.agt.sqr);
        endtask
    endclass

    class apb_rand_test extends apb_base_test;
        `uvm_component_utils(apb_rand_test)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        task run_sequences();
            apb_directed_seq d = apb_directed_seq::type_id::create("d");
            apb_random_seq   r = apb_random_seq  ::type_id::create("r");
            d.start(env.agt.sqr);          // first the directed checklist
            r.count = 1000;
            r.start(env.agt.sqr);          // then 1000 random transfers
        endtask
    endclass

endpackage