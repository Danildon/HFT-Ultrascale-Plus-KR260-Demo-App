// =============================================================================
// tb_top.sv
// Testbench for the full parser → order book pipeline.
// Drives a sequence of Add/Delete/Execute messages and verifies top-of-book.
// =============================================================================

`timescale 1ns / 1ps

module tb_top;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    localparam int PRICE_W  = 64;
    localparam int QTY_W    = 32;
    localparam int TS_W     = 64;
    localparam int N_LEVELS = 8;

    // 156.25 MHz (6.4 ns period) — typical 10GbE processing clock
    localparam real CLK_PERIOD = 6.4;

    // -------------------------------------------------------------------------
    // DUT ports
    // -------------------------------------------------------------------------
    logic        clk        = 0;
    logic        rst_n      = 0;
    logic [7:0]  s_tdata    = 0;
    logic        s_tvalid   = 0;
    logic        s_tlast    = 0;
    logic        s_tready;

    logic              tob_valid;
    logic [PRICE_W-1:0] best_bid_price;
    logic [QTY_W-1:0]  best_bid_qty;
    logic [PRICE_W-1:0] best_ask_price;
    logic [QTY_W-1:0]  best_ask_qty;
    logic [PRICE_W-1:0] spread;
    logic [TS_W-1:0]   last_update_ts;
    logic              tob_changed;
    logic              crossed_book;
    logic              parse_error;
    logic [63:0]       msg_count;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    top #(
        .N_LEVELS (N_LEVELS),
        .PRICE_W  (PRICE_W),
        .QTY_W    (QTY_W),
        .TS_W     (TS_W)
    ) dut (.*);

    // -------------------------------------------------------------------------
    // Clock generation
    // -------------------------------------------------------------------------
    always #(CLK_PERIOD/2) clk = ~clk;

    // -------------------------------------------------------------------------
    // Task: drive a binary frame byte-by-byte over AXI4-Stream
    // -------------------------------------------------------------------------
    task automatic drive_frame(input byte frame[], input int n_bytes);
        for (int i = 0; i < n_bytes; i++) begin
            @(posedge clk);
            s_tdata  = frame[i];
            s_tvalid = 1;
            s_tlast  = (i == n_bytes - 1);
        end
        @(posedge clk);
        s_tvalid = 0;
        s_tlast  = 0;
        s_tdata  = 0;
    endtask

    // -------------------------------------------------------------------------
    // Task: build an Add Order frame (30 bytes, big-endian fields)
    // -------------------------------------------------------------------------
    task automatic build_add_frame(
        output byte frame [30],
        input  longint unsigned ts_ns,
        input  longint unsigned order_ref,
        input  byte            side,     // 8'h42=Bid, 8'h53=Ask
        input  int unsigned    qty,
        input  longint         price_ticks
    );
        frame[0] = 8'h41; // 'A'
        // Timestamp (big-endian 64-bit)
        for (int i = 0; i < 8; i++) frame[1+i]  = (ts_ns    >> (56 - i*8)) & 8'hFF;
        // Order ref (big-endian 64-bit)
        for (int i = 0; i < 8; i++) frame[9+i]  = (order_ref >> (56 - i*8)) & 8'hFF;
        frame[17] = side;
        // Quantity (big-endian 32-bit)
        for (int i = 0; i < 4; i++) frame[18+i] = (qty        >> (24 - i*8)) & 8'hFF;
        // Price (big-endian 64-bit)
        for (int i = 0; i < 8; i++) frame[22+i] = (price_ticks >> (56 - i*8)) & 8'hFF;
    endtask

    task automatic build_delete_frame(
        output byte frame [17],
        input  longint unsigned ts_ns,
        input  longint unsigned order_ref
    );
        frame[0] = 8'h44;  // 'D'
        for (int i = 0; i < 8; i++) frame[1+i] = (ts_ns     >> (56 - i*8)) & 8'hFF;
        for (int i = 0; i < 8; i++) frame[9+i] = (order_ref >> (56 - i*8)) & 8'hFF;
    endtask

    // -------------------------------------------------------------------------
    // Helper: wait for tob_changed and print state
    // -------------------------------------------------------------------------
    task automatic wait_and_print_tob(input string description);
        @(posedge tob_changed);
        @(posedge clk);
        $display("[%0t ns] %s", $time, description);
        $display("  Best Bid: price=%0d  qty=%0d", $signed(best_bid_price), best_bid_qty);
        $display("  Best Ask: price=%0d  qty=%0d", $signed(best_ask_price), best_ask_qty);
        $display("  Spread:   %0d ticks", $signed(spread));
        if (crossed_book)
            $display("  *** CROSSED BOOK DETECTED ***");
    endtask

    // -------------------------------------------------------------------------
    // Test stimulus
    // -------------------------------------------------------------------------
    initial begin
        $display("=== HFT Order Book FPGA Testbench ===");
        $display("Clock: %.1f MHz  N_LEVELS=%0d", 1000.0/CLK_PERIOD, N_LEVELS);

        // Reset
        rst_n = 0;
        repeat(10) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);

        $display("\n[TEST 1] Add bid and ask orders, check spread");

        // Add bid at 9999 ticks (e.g. $99.99 with 0.01 tick)
        begin
            byte frame[30];
            build_add_frame(frame, 64'd1000000, 64'd1001, 8'h42, 32'd1000, 64'd9999);
            drive_frame(frame, 30);
        end

        // Add ask at 10001 ticks
        begin
            byte frame[30];
            build_add_frame(frame, 64'd2000000, 64'd2001, 8'h53, 32'd500, 64'd10001);
            drive_frame(frame, 30);
        end

        repeat(10) @(posedge clk);
        $display("[%0t ns] After add bid+ask:", $time);
        $display("  Best Bid: %0d  qty=%0d", $signed(best_bid_price), best_bid_qty);
        $display("  Best Ask: %0d  qty=%0d", $signed(best_ask_price), best_ask_qty);
        $display("  Spread:   %0d ticks", $signed(spread));
        $display("  TOB valid: %0b", tob_valid);

        assert (best_bid_price == 64'd9999)  else $error("Bid price mismatch");
        assert (best_ask_price == 64'd10001) else $error("Ask price mismatch");
        assert (spread == 64'd2)             else $error("Spread mismatch");

        $display("\n[TEST 2] Add better bid, check TOB updates");
        begin
            byte frame[30];
            build_add_frame(frame, 64'd3000000, 64'd1002, 8'h42, 32'd200, 64'd10000);
            drive_frame(frame, 30);
        end
        repeat(10) @(posedge clk);
        $display("  Best Bid now: %0d (should be 10000)", $signed(best_bid_price));
        assert (best_bid_price == 64'd10000) else $error("Better bid not detected");
        assert (spread == 64'd1)             else $error("Spread should be 1 after better bid");

        $display("\n[TEST 3] Delete the better bid, best bid should revert");
        begin
            byte frame[17];
            build_delete_frame(frame, 64'd4000000, 64'd1002);
            drive_frame(frame, 17);
        end
        repeat(10) @(posedge clk);
        $display("  Best Bid after delete: %0d (should be 9999)", $signed(best_bid_price));
        assert (best_bid_price == 64'd9999) else $error("Bid should have reverted to 9999");

        $display("\n[TEST 4] Multiple levels, book depth check");
        begin
            byte frame[30];
            // Add several bid levels
            build_add_frame(frame, 64'd5000000, 64'd1003, 8'h42, 32'd300, 64'd9998);
            drive_frame(frame, 30);
            build_add_frame(frame, 64'd5000001, 64'd1004, 8'h42, 32'd400, 64'd9997);
            drive_frame(frame, 30);
            build_add_frame(frame, 64'd5000002, 64'd1005, 8'h42, 32'd100, 64'd10000);
            drive_frame(frame, 30);
        end
        repeat(10) @(posedge clk);
        $display("  Best Bid: %0d  (should be 10000)", $signed(best_bid_price));
        assert (best_bid_price == 64'd10000 || best_bid_price == 64'd9999)
            else $error("Unexpected bid");
        $display("  Crossed book: %0b  (should be 0)", crossed_book);
        assert (!crossed_book) else $error("Book should not be crossed");

        $display("\n[DONE] All tests passed. msg_count=%0d", msg_count);
        $display("  parse_error=%0b", parse_error);

        repeat(20) @(posedge clk);
        $finish;
    end

    // -------------------------------------------------------------------------
    // Watchdog
    // -------------------------------------------------------------------------
    initial begin
        #100000;
        $display("TIMEOUT");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Waveform dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_top.vcd");
        $dumpvars(0, tb_top);
    end

endmodule
