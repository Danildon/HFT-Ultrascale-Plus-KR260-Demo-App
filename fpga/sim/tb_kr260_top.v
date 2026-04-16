// tb_kr260_top.v
// Self-checking testbench for kr260_top (parser + engine + axi_lite).
// No VIP needed — we drive AXI4-Stream and AXI4-Lite signals directly.
// Simulator: XSim, Icarus Verilog, or ModelSim (plain Verilog, no SV).
//
// What it tests:
//   1. Reset behaviour  — registers read 0x0 after reset
//   2. Add bid orders   — best_bid updates correctly
//   3. Add ask orders   — best_ask updates, TOB valid set
//   4. Execute order    — quantity reduces
//   5. Delete order     — price level removed
//   6. Spread check     — ask − bid is correct after above sequence
//
// Expected final TOB:
//   best_bid = $99.99 (9999 ticks)   qty = 100
//   best_ask = $100.01 (10001 ticks)  qty = 150
//   spread   = $0.02  (2 ticks)

`timescale 1ns/1ps

module tb_kr260_top;

    // -----------------------------------------------------------------------
    // Clock and reset
    // -----------------------------------------------------------------------
    reg clk, rst_n;

    initial clk = 0;
    always #5 clk = ~clk;   // 100 MHz (10 ns period, close enough to pl_clk0)

    // -----------------------------------------------------------------------
    // DUT ports
    // -----------------------------------------------------------------------
    // AXI4-Stream drive
    reg  [7:0]  axis_tdata;
    reg         axis_tvalid;
    reg         axis_tlast;
    wire        axis_tready;

    // AXI4-Lite drive (read channel only — we only read registers)
    reg  [5:0]  axi_araddr;
    reg         axi_arvalid;
    wire        axi_arready;
    wire [31:0] axi_rdata;
    wire [1:0]  axi_rresp;
    wire        axi_rvalid;
    reg         axi_rready;

    // AXI4-Lite write channel (needed for DUT ports, tie off)
    reg  [5:0]  axi_awaddr;
    reg         axi_awvalid;
    wire        axi_awready;
    reg  [31:0] axi_wdata;
    reg  [3:0]  axi_wstrb;
    reg         axi_wvalid;
    wire        axi_wready;
    wire [1:0]  axi_bresp;
    wire        axi_bvalid;
    reg         axi_bready;

    // -----------------------------------------------------------------------
    // DUT instantiation
    // -----------------------------------------------------------------------
    kr260_top #(
        .N_LEVELS (8),
        .PRICE_W  (64),
        .QTY_W    (32),
        .TS_W     (64)
    ) dut (
        .pl_clk0        (clk),
        .pl_clk1        (clk),
        .pl_resetn0     (rst_n),

        .s_axi_aclk     (clk),
        .s_axi_aresetn  (rst_n),
        .s_axi_awaddr   (axi_awaddr),
        .s_axi_awvalid  (axi_awvalid),
        .s_axi_awready  (axi_awready),
        .s_axi_wdata    (axi_wdata),
        .s_axi_wstrb    (axi_wstrb),
        .s_axi_wvalid   (axi_wvalid),
        .s_axi_wready   (axi_wready),
        .s_axi_bresp    (axi_bresp),
        .s_axi_bvalid   (axi_bvalid),
        .s_axi_bready   (axi_bready),
        .s_axi_araddr   (axi_araddr),
        .s_axi_arvalid  (axi_arvalid),
        .s_axi_arready  (axi_arready),
        .s_axi_rdata    (axi_rdata),
        .s_axi_rresp    (axi_rresp),
        .s_axi_rvalid   (axi_rvalid),
        .s_axi_rready   (axi_rready),

        .s_axis_tdata   (axis_tdata),
        .s_axis_tvalid  (axis_tvalid),
        .s_axis_tlast   (axis_tlast),
        .s_axis_tready  (axis_tready),

        .pl_led_0       (),
        .pl_led_1       (),
        .pl_led_2       (),
        .pl_led_3       ()
    );

    // -----------------------------------------------------------------------
    // Register address map (matches tob_axi_lite.v)
    // -----------------------------------------------------------------------
    localparam A_STATUS       = 6'h00;
    localparam A_TOB_CHANGED  = 6'h04;
    localparam A_MSG_CNT_LO   = 6'h08;
    localparam A_MSG_CNT_HI   = 6'h0C;
    localparam A_BID_PRICE_LO = 6'h10;
    localparam A_BID_PRICE_HI = 6'h14;
    localparam A_BID_QTY      = 6'h18;
    localparam A_ASK_PRICE_LO = 6'h1C;
    localparam A_ASK_PRICE_HI = 6'h20;
    localparam A_ASK_QTY      = 6'h24;
    localparam A_SPREAD_LO    = 6'h28;
    localparam A_SPREAD_HI    = 6'h2C;

    // -----------------------------------------------------------------------
    // Task: send one binary message over AXI4-Stream
    // One byte per clock, tlast on final byte.
    // -----------------------------------------------------------------------
    task send_msg;
        input [239:0] msg_bytes;  // up to 30 bytes, MSB first
        input integer msg_len;
        integer i;
        begin
            for (i = 0; i < msg_len; i = i + 1) begin
                @(posedge clk);
                axis_tdata  = msg_bytes[239 - i*8 -: 8];
                axis_tvalid = 1'b1;
                axis_tlast  = (i == msg_len - 1) ? 1'b1 : 1'b0;
                // Wait for tready
                while (!axis_tready) @(posedge clk);
            end
            @(posedge clk);
            axis_tvalid = 1'b0;
            axis_tlast  = 1'b0;
            axis_tdata  = 8'h0;
        end
    endtask

    // -----------------------------------------------------------------------
    // Task: AXI4-Lite register read
    // Returns value in reg_val
    // -----------------------------------------------------------------------
    reg [31:0] reg_val;

    task axi_read;
        input [5:0] addr;
        begin
            @(posedge clk);
            axi_araddr  = addr;
            axi_arvalid = 1'b1;
            axi_rready  = 1'b1;
            @(posedge clk);
            while (!axi_arready) @(posedge clk);
            axi_arvalid = 1'b0;
            while (!axi_rvalid) @(posedge clk);
            reg_val = axi_rdata;
            @(posedge clk);
        end
    endtask

    // -----------------------------------------------------------------------
    // Task: check and report
    // -----------------------------------------------------------------------
    integer pass_count, fail_count;

    task check;
        input [63:0]  actual;
        input [63:0]  expected;
        input [127:0] label;
        begin
            if (actual === expected) begin
                $display("  PASS  %0s  =  %0d  (0x%08X)", label, actual, actual);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL  %0s  got %0d (0x%08X)  expected %0d (0x%08X)",
                         label, actual, actual, expected, expected);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Message builders (big-endian wire format, MSB first in the 240-bit word)
    // Layout: [239:232]=type [231:168]=ts [167:104]=ref [103:96]=side
    //         [95:64]=qty [63:0]=price
    //
    // Unused bytes (Delete=17, Execute/Update=21) are zero-padded at LSB.
    // -----------------------------------------------------------------------
    function [239:0] make_add;
        input [63:0] ts;
        input [63:0] ref;
        input [7:0]  side;   // 'B'=0x42  'S'=0x53
        input [31:0] qty;
        input [63:0] price;
        begin
            make_add = {8'h41, ts, ref, side, qty, price};
        end
    endfunction

    function [239:0] make_delete;
        input [63:0] ts;
        input [63:0] ref;
        begin
            // 17 bytes: type(1)+ts(8)+ref(8), left-aligned in 240 bits
            make_delete = {8'h44, ts, ref, 88'h0};
        end
    endfunction

    function [239:0] make_execute;
        input [63:0] ts;
        input [63:0] ref;
        input [31:0] exec_qty;
        begin
            // 21 bytes: type(1)+ts(8)+ref(8)+exec_qty(4)
            make_execute = {8'h45, ts, ref, exec_qty, 56'h0};
        end
    endfunction

    // -----------------------------------------------------------------------
    // Pipeline drain helper: wait enough cycles for the 3-stage parser
    // + 1 engine cycle + 2 CDC cycles to propagate
    // -----------------------------------------------------------------------
    task drain;
        begin
            repeat (8) @(posedge clk);
        end
    endtask

    // -----------------------------------------------------------------------
    // Main test
    // -----------------------------------------------------------------------
    reg [63:0] bid_price, ask_price, spread;
    reg [31:0] bid_qty, ask_qty;
    reg [31:0] status, msg_cnt;

    initial begin
        // Dump waveforms (XSim / Icarus)
        $dumpfile("tb_kr260_top.vcd");
        $dumpvars(0, tb_kr260_top);

        pass_count  = 0;
        fail_count  = 0;

        // Tie off write channel (not tested here)
        axi_awaddr  = 0;  axi_awvalid = 0;
        axi_wdata   = 0;  axi_wstrb   = 0;  axi_wvalid = 0;
        axi_bready  = 1;
        // Stream idle
        axis_tdata  = 0;  axis_tvalid = 0;  axis_tlast = 0;
        // Read channel idle
        axi_araddr  = 0;  axi_arvalid = 0;  axi_rready = 0;

        // ---- Reset --------------------------------------------------------
        rst_n = 0;
        repeat(4) @(posedge clk);
        rst_n = 1;
        repeat(4) @(posedge clk);

        $display("\n=== Test 1: reset state ===");
        axi_read(A_STATUS);        check(reg_val, 32'h0, "STATUS after reset");
        axi_read(A_MSG_CNT_LO);    check(reg_val, 32'h0, "MSG_CNT_LO after reset");
        axi_read(A_BID_PRICE_LO);  check(reg_val, 32'h0, "BID_PRICE_LO after reset");

        // ---- Add bid @ 9999 ticks ($99.99) qty=200 -------------------------
        $display("\n=== Test 2: add bid $99.99 qty=200 ===");
        send_msg(make_add(64'd1000, 64'd1, 8'h42, 32'd200, 64'd9999), 30);
        drain;

        axi_read(A_MSG_CNT_LO);    check(reg_val, 32'h1, "MSG_CNT after 1 msg");
        axi_read(A_STATUS);
        $display("  STATUS = 0x%08X  (tob_valid=%0d)", reg_val, reg_val[0]);

        // ---- Add bid @ 9998 ticks ($99.98) qty=100 -------------------------
        $display("\n=== Test 3: add bid $99.98 qty=100 ===");
        send_msg(make_add(64'd2000, 64'd2, 8'h42, 32'd100, 64'd9998), 30);
        drain;

        axi_read(A_MSG_CNT_LO);    check(reg_val, 32'h2, "MSG_CNT after 2 msgs");
        axi_read(A_BID_PRICE_LO);
        bid_price = reg_val;
        // Best bid should still be 9999 (higher wins)
        check(bid_price, 32'd9999, "BID_PRICE_LO (best=9999)");

        // ---- Add ask @ 10001 ticks ($100.01) qty=150 -----------------------
        $display("\n=== Test 4: add ask $100.01 qty=150 ===");
        send_msg(make_add(64'd3000, 64'd3, 8'h53, 32'd150, 64'd10001), 30);
        drain;

        axi_read(A_STATUS);
        check(reg_val[0], 1'b1, "tob_valid (both sides present)");
        axi_read(A_ASK_PRICE_LO);  check(reg_val, 32'd10001, "ASK_PRICE_LO = 10001");
        axi_read(A_ASK_QTY);       check(reg_val, 32'd150,   "ASK_QTY = 150");
        axi_read(A_SPREAD_LO);     check(reg_val, 32'd2,     "SPREAD = 2 ticks ($0.02)");

        // ---- Add ask @ 10002 ticks ($100.02) qty=75 ------------------------
        $display("\n=== Test 5: add ask $100.02 qty=75 (best ask unchanged) ===");
        send_msg(make_add(64'd4000, 64'd4, 8'h53, 32'd75, 64'd10002), 30);
        drain;

        axi_read(A_ASK_PRICE_LO);  check(reg_val, 32'd10001, "ASK still 10001 (10001<10002)");

        // ---- Execute ref=1 (bid@9999) for 100 qty --------------------------
        $display("\n=== Test 6: execute 100 @ bid ref=1 (qty 200->100) ===");
        send_msg(make_execute(64'd5000, 64'd1, 32'd100), 21);
        drain;

        axi_read(A_BID_PRICE_LO);  check(reg_val, 32'd9999, "BID still 9999 (partial fill)");
        axi_read(A_BID_QTY);       check(reg_val, 32'd100,  "BID_QTY = 100 (was 200)");

        // ---- Delete ask ref=3 (@10001) -------------------------------------
        $display("\n=== Test 7: delete ask ref=3 (@10001) ===");
        send_msg(make_delete(64'd6000, 64'd3), 17);
        drain;

        axi_read(A_ASK_PRICE_LO);  check(reg_val, 32'd10002, "ASK now 10002 (10001 deleted)");
        axi_read(A_ASK_QTY);       check(reg_val, 32'd75,    "ASK_QTY = 75");
        axi_read(A_SPREAD_LO);     check(reg_val, 32'd3,     "SPREAD = 3 ticks ($0.03)");

        // ---- Final message count -------------------------------------------
        $display("\n=== Test 8: message count ===");
        axi_read(A_MSG_CNT_LO);    check(reg_val, 32'd6, "MSG_CNT = 6 total messages");

        // ---- Parse error should be clear ----------------------------------
        $display("\n=== Test 9: no parse errors ===");
        axi_read(A_STATUS);        check(reg_val[2], 1'b0, "parse_error = 0");

        // ---- Summary -------------------------------------------------------
        $display("\n========================================");
        $display("  PASSED: %0d   FAILED: %0d", pass_count, fail_count);
        $display("========================================\n");

        if (fail_count > 0)
            $display("RESULT: FAIL");
        else
            $display("RESULT: PASS");

        #100;
        $finish;
    end

    // -----------------------------------------------------------------------
    // Timeout watchdog
    // -----------------------------------------------------------------------
    initial begin
        #200000;
        $display("TIMEOUT — simulation exceeded 200 µs");
        $finish;
    end

endmodule
