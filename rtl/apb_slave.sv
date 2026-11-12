// =====================================================================
// apb_slave.sv - APB slave with 4 registers (the DUT)
//
// APB = Advanced Peripheral Bus, a simple bus used to talk to the
// control/status registers of a chip block.
//
// Register map (32-bit registers, word addresses):
//   0x00 CTRL    read/write. Bits [1:0] = number of WAIT cycles the slave
//                inserts before it answers (0 to 3).
//   0x04 DATA    read/write.
//   0x08 STATUS  READ-ONLY. Low 8 bits = number of successful writes so far.
//   0x0C SCRATCH read/write.
// Any other address -> error (PSLVERR = 1).
// Writing to STATUS  -> error (PSLVERR = 1) and nothing changes.
//
// APB transfer, in plain words:
//   cycle 1 (SETUP) : master puts address/data on the bus, PSEL=1, PENABLE=0
//   cycle 2+ (ACCESS): master sets PENABLE=1. Slave answers with PREADY=1
//                     when it is done. If PREADY=0 the master must wait.
//   The transfer ends in the cycle where PSEL=1, PENABLE=1, PREADY=1.
//
// Bugs can be switched on with +define+BUG_xxx (used to prove that the
// testbench really catches mistakes).
// =====================================================================
`timescale 1ns/1ps
module apb_slave (
    input  logic        pclk,
    input  logic        presetn,     // active low reset
    input  logic        psel,
    input  logic        penable,
    input  logic        pwrite,
    input  logic [7:0]  paddr,
    input  logic [31:0] pwdata,
    output logic [31:0] prdata,
    output logic        pready,
    output logic        pslverr
);

    localparam ADDR_CTRL    = 8'h00;
    localparam ADDR_DATA    = 8'h04;
    localparam ADDR_STATUS  = 8'h08;
    localparam ADDR_SCRATCH = 8'h0C;

    logic [31:0] ctrl, data, scratch;
    logic [7:0]  wr_count;       // STATUS register
    logic [1:0]  wait_cnt;       // wait cycles already spent in this transfer

    wire in_access = psel && penable;               // access phase
    wire [1:0] wait_cfg = ctrl[1:0];                // how many waits we want

    wire addr_ok   = (paddr == ADDR_CTRL) || (paddr == ADDR_DATA) ||
                     (paddr == ADDR_STATUS) || (paddr == ADDR_SCRATCH);
    wire is_status = (paddr == ADDR_STATUS);

    // ---- PREADY: 1 when we have waited long enough ----
`ifdef BUG_PREADY_EARLY
    // bug: answers one cycle too early when 3 waits are configured
    assign pready = !in_access ? 1'b1 : (wait_cnt >= ((wait_cfg == 2'd3) ? 2'd2 : wait_cfg));
`else
    assign pready = !in_access ? 1'b1 : (wait_cnt >= wait_cfg);
`endif

    wire xfer_done = in_access && pready;           // last cycle of a transfer

    // ---- PSLVERR: only meaningful in the last cycle of a transfer ----
`ifdef BUG_NO_ERR_BAD_ADDR
    // bug: bad address does not raise an error
    assign pslverr = xfer_done && pwrite && is_status;
`elsif BUG_NO_ERR_RO_WRITE
    // bug: writing the read-only register does not raise an error
    assign pslverr = xfer_done && !addr_ok;
`else
    assign pslverr = xfer_done && (!addr_ok || (pwrite && is_status));
`endif

    // ---- read data (combinational mux) ----
    always_comb begin
        case (paddr)
            ADDR_CTRL:    prdata = ctrl;
            ADDR_DATA:    prdata = data;
            ADDR_STATUS:  prdata = {24'h0, wr_count};
`ifdef BUG_READ_WRONG
            ADDR_SCRATCH: prdata = data;       // bug: SCRATCH read returns DATA
`else
            ADDR_SCRATCH: prdata = scratch;
`endif
            default:      prdata = 32'h0;
        endcase
    end

    // ---- a write really happens only at the end of an access phase ----
`ifdef BUG_WRITE_IN_SETUP
    wire do_write = psel && pwrite && !(in_access && !pready);   // bug: writes already in setup phase
`else
    wire do_write = xfer_done && pwrite;
`endif

    always_ff @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            ctrl     <= 32'h0;
            data     <= 32'h0;
`ifndef BUG_RESET_SCRATCH
            scratch  <= 32'h0;
`endif
            wr_count <= 8'h0;
            wait_cnt <= 2'h0;
        end else begin
            // wait counter: counts while we wait, clears when transfer ends
            if (in_access && !pready) wait_cnt <= wait_cnt + 1'b1;
            else                      wait_cnt <= 2'h0;

            if (do_write) begin
                case (paddr)
                    ADDR_CTRL:    begin ctrl    <= pwdata; wr_count <= wr_count + 1'b1; end
                    ADDR_DATA:    begin data    <= pwdata; wr_count <= wr_count + 1'b1; end
                    ADDR_SCRATCH: begin scratch <= pwdata; wr_count <= wr_count + 1'b1; end
                    default: ;   // STATUS and bad addresses: ignored
                endcase
            end
        end
    end

endmodule
