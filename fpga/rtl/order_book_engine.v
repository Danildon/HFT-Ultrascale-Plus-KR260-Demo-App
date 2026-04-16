`timescale 1ns/1ps

module order_book_engine #(
    parameter N_LEVELS = 8,
    parameter PRICE_W  = 64,
    parameter QTY_W    = 32,
    parameter TS_W     = 64
)(
    input  wire              clk,
    input  wire              rst_n,

    input  wire              in_valid,
    input  wire [3:0]        in_msg_type,
    input  wire              in_side,
    input  wire [63:0]       in_order_ref,
    input  wire [QTY_W-1:0]  in_quantity,
    input  wire [PRICE_W-1:0] in_price,
    input  wire [TS_W-1:0]   in_timestamp,

    output reg               tob_valid,
    output reg [PRICE_W-1:0] best_bid_price,
    output reg [QTY_W-1:0]   best_bid_qty,
    output reg [PRICE_W-1:0] best_ask_price,
    output reg [QTY_W-1:0]   best_ask_qty,
    output reg [PRICE_W-1:0] spread,
    output reg [TS_W-1:0]    last_update_ts,

    output reg               tob_changed,
    output reg               crossed_book
);

    // ------------------------------------------------------------
    // BOOK STORAGE
    // ------------------------------------------------------------
    reg bid_valid [0:N_LEVELS-1];
    reg [PRICE_W-1:0] bid_price [0:N_LEVELS-1];
    reg [QTY_W-1:0]   bid_qty   [0:N_LEVELS-1];

    reg ask_valid [0:N_LEVELS-1];
    reg [PRICE_W-1:0] ask_price [0:N_LEVELS-1];
    reg [QTY_W-1:0]   ask_qty   [0:N_LEVELS-1];

    // ------------------------------------------------------------
    // STAGE 0: COMBINATIONAL ANALYSIS
    // ------------------------------------------------------------
    integer i;

    reg [3:0] bid_match_idx, bid_empty_idx;
    reg [3:0] ask_match_idx, ask_empty_idx;

    reg [PRICE_W-1:0] b0,b1,b2,b3,b4,b5,b6,b7;
    reg [PRICE_W-1:0] a0,a1,a2,a3,a4,a5,a6,a7;

    reg [QTY_W-1:0] bq0,bq1,bq2,bq3,bq4,bq5,bq6,bq7;
    reg [QTY_W-1:0] aq0,aq1,aq2,aq3,aq4,aq5,aq6,aq7;

    reg any_bid_valid, any_ask_valid;

    reg [PRICE_W-1:0] best_bid_combo;
    reg [PRICE_W-1:0] best_ask_combo;

    reg [QTY_W-1:0] best_bid_qty_combo;
    reg [QTY_W-1:0] best_ask_qty_combo;

    always @(*) begin

        // defaults
        bid_match_idx = N_LEVELS;
        bid_empty_idx = N_LEVELS;
        ask_match_idx = N_LEVELS;
        ask_empty_idx = N_LEVELS;

        any_bid_valid = 0;
        any_ask_valid = 0;

        best_bid_combo = 0;
        best_ask_combo = {PRICE_W{1'b1}};

        // --------------------------------------------------------
        // scan + match (no priority encoding)
        // --------------------------------------------------------
        for (i = 0; i < N_LEVELS; i = i + 1) begin
            if (bid_valid[i]) begin
                any_bid_valid = 1;
                if (bid_price[i] == in_price)
                    bid_match_idx = i;
            end else begin
                bid_empty_idx = i;
            end

            if (ask_valid[i]) begin
                any_ask_valid = 1;
                if (ask_price[i] == in_price)
                    ask_match_idx = i;
            end else begin
                ask_empty_idx = i;
            end
        end

        // --------------------------------------------------------
        // UNROLLED BEST BID (tree style)
        // --------------------------------------------------------
        b0 = (bid_valid[0]) ? bid_price[0] : 0;
        b1 = (bid_valid[1]) ? bid_price[1] : 0;
        b2 = (bid_valid[2]) ? bid_price[2] : 0;
        b3 = (bid_valid[3]) ? bid_price[3] : 0;
        b4 = (bid_valid[4]) ? bid_price[4] : 0;
        b5 = (bid_valid[5]) ? bid_price[5] : 0;
        b6 = (bid_valid[6]) ? bid_price[6] : 0;
        b7 = (bid_valid[7]) ? bid_price[7] : 0;

        best_bid_combo =
            (b0>b1?b0:b1 > b2?b2:b3) > (b4>b5?b4:b5 > b6?b6:b7) ?
            (b0>b1?b0:b1 > b2?b2:b3) :
            (b4>b5?b4:b5 > b6?b6:b7);

        // --------------------------------------------------------
        // UNROLLED BEST ASK
        // --------------------------------------------------------
        a0 = (ask_valid[0]) ? ask_price[0] : {PRICE_W{1'b1}};
        a1 = (ask_valid[1]) ? ask_price[1] : {PRICE_W{1'b1}};
        a2 = (ask_valid[2]) ? ask_price[2] : {PRICE_W{1'b1}};
        a3 = (ask_valid[3]) ? ask_price[3] : {PRICE_W{1'b1}};
        a4 = (ask_valid[4]) ? ask_price[4] : {PRICE_W{1'b1}};
        a5 = (ask_valid[5]) ? ask_price[5] : {PRICE_W{1'b1}};
        a6 = (ask_valid[6]) ? ask_price[6] : {PRICE_W{1'b1}};
        a7 = (ask_valid[7]) ? ask_price[7] : {PRICE_W{1'b1}};

        best_ask_combo =
            (a0<a1?a0:a1 < a2?a2:a3) < (a4<a5?a4:a5 < a6?a6:a7) ?
            (a0<a1?a0:a1 < a2?a2:a3) :
            (a4<a5?a4:a5 < a6?a6:a7);

    end

    // ------------------------------------------------------------
    // STAGE 1: REGISTER SNAPSHOT (BREAK CRITICAL PATH)
    // ------------------------------------------------------------
    reg [3:0] bid_match_r, bid_empty_r;
    reg [3:0] ask_match_r, ask_empty_r;

    reg [PRICE_W-1:0] best_bid_r, best_ask_r;
    reg any_bid_r, any_ask_r;

    always @(posedge clk) begin
        if (!rst_n) begin
            bid_match_r <= N_LEVELS;
            bid_empty_r <= N_LEVELS;
            ask_match_r <= N_LEVELS;
            ask_empty_r <= N_LEVELS;

            best_bid_r <= 0;
            best_ask_r <= 0;

            any_bid_r <= 0;
            any_ask_r <= 0;
        end else begin
            bid_match_r <= bid_match_idx;
            bid_empty_r <= bid_empty_idx;
            ask_match_r <= ask_match_idx;
            ask_empty_r <= ask_empty_idx;

            best_bid_r <= best_bid_combo;
            best_ask_r <= best_ask_combo;

            any_bid_r <= any_bid_valid;
            any_ask_r <= any_ask_valid;
        end
    end

    // ------------------------------------------------------------
    // STAGE 2: UPDATE BOOK (NO COMBINATIONAL DEPENDENCY)
    // ------------------------------------------------------------
    integer k;
    reg [PRICE_W-1:0] prev_best_bid, prev_best_ask;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k=0;k<N_LEVELS;k=k+1) begin
                bid_valid[k] <= 0;
                ask_valid[k] <= 0;
                bid_price[k] <= 0;
                ask_price[k] <= 0;
                bid_qty[k] <= 0;
                ask_qty[k] <= 0;
            end

            tob_changed <= 0;
            prev_best_bid <= 0;
            prev_best_ask <= {PRICE_W{1'b1}};
        end else begin

            tob_changed <= 0;

            if (in_valid) begin

                last_update_ts <= in_timestamp;

                case (in_msg_type)

                // ADD
                0: begin
                    if (!in_side) begin
                        if (bid_match_r < N_LEVELS)
                            bid_qty[bid_match_r] <= bid_qty[bid_match_r] + in_quantity;
                        else if (bid_empty_r < N_LEVELS) begin
                            bid_valid[bid_empty_r] <= 1;
                            bid_price[bid_empty_r] <= in_price;
                            bid_qty[bid_empty_r] <= in_quantity;
                        end
                    end else begin
                        if (ask_match_r < N_LEVELS)
                            ask_qty[ask_match_r] <= ask_qty[ask_match_r] + in_quantity;
                        else if (ask_empty_r < N_LEVELS) begin
                            ask_valid[ask_empty_r] <= 1;
                            ask_price[ask_empty_r] <= in_price;
                            ask_qty[ask_empty_r] <= in_quantity;
                        end
                    end
                end

                // UPDATE / EXEC
                1,3: begin
                    if (!in_side) begin
                        if (bid_match_r < N_LEVELS)
                            if (bid_qty[bid_match_r] <= in_quantity)
                                bid_valid[bid_match_r] <= 0;
                            else
                                bid_qty[bid_match_r] <= bid_qty[bid_match_r] - in_quantity;
                    end else begin
                        if (ask_match_r < N_LEVELS)
                            if (ask_qty[ask_match_r] <= in_quantity)
                                ask_valid[ask_match_r] <= 0;
                            else
                                ask_qty[ask_match_r] <= ask_qty[ask_match_r] - in_quantity;
                    end
                end

                // DELETE
                2: begin
                    if (!in_side) begin
                        if (bid_match_r < N_LEVELS)
                            bid_valid[bid_match_r] <= 0;
                    end else begin
                        if (ask_match_r < N_LEVELS)
                            ask_valid[ask_match_r] <= 0;
                    end
                end

                endcase

                // TOB logic (now safe)
                if ((best_bid_r != prev_best_bid) ||
                    (best_ask_r != prev_best_ask))
                    tob_changed <= 1;

                prev_best_bid <= best_bid_r;
                prev_best_ask <= best_ask_r;
            end
        end
    end

    // ------------------------------------------------------------
    // OUTPUT REGISTER STAGE
    // ------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tob_valid <= 0;
        end else begin
            tob_valid <= any_bid_r & any_ask_r;

            best_bid_price <= best_bid_r;
            best_ask_price <= best_ask_r;

            crossed_book <= any_bid_r & any_ask_r &
                           (best_bid_r >= best_ask_r);

            spread <= (any_bid_r & any_ask_r)
                      ? best_ask_r - best_bid_r
                      : 0;
        end
    end

endmodule