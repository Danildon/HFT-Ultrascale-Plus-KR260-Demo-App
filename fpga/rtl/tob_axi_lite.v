// tob_axi_lite.v
// AXI4-Lite slave — exposes top-of-book registers to the Cortex-A53 APU.
// Plain Verilog (IEEE 1364-2001)
//
// Fix: tob_changed_latch and parse_error_latch are each driven from a single
// always block that handles both set (from input pulses) and clear (from
// register read/write). This avoids the multi-driver error.
//
// Register map (base address set in Vivado Address Editor):
//   0x00 STATUS       [0]=tob_valid [1]=crossed [2]=parse_err (write 1 to clear)
//   0x04 TOB_CHANGED  reads 1 if TOB changed since last read; clears on read
//   0x08 MSG_CNT_LO   message count [31:0]
//   0x0C MSG_CNT_HI   message count [63:32]
//   0x10 BID_PRICE_LO best bid price ticks [31:0]
//   0x14 BID_PRICE_HI best bid price ticks [63:32]
//   0x18 BID_QTY      best bid quantity
//   0x1C ASK_PRICE_LO best ask price ticks [31:0]
//   0x20 ASK_PRICE_HI best ask price ticks [63:32]
//   0x24 ASK_QTY      best ask quantity
//   0x28 SPREAD_LO    spread in ticks [31:0]
//   0x2C SPREAD_HI    spread in ticks [63:32]

`timescale 1ns/1ps

module tob_axi_lite #(
    parameter PRICE_W = 64,
    parameter QTY_W   = 32,
    parameter TS_W    = 64,
    parameter ADDR_W  = 6
)(
    input  wire              s_axi_aclk,
    input  wire              s_axi_aresetn,

    input  wire [ADDR_W-1:0] s_axi_awaddr,
    input  wire              s_axi_awvalid,
    output reg               s_axi_awready,

    input  wire [31:0]       s_axi_wdata,
    input  wire [3:0]        s_axi_wstrb,
    input  wire              s_axi_wvalid,
    output reg               s_axi_wready,

    output reg [1:0]         s_axi_bresp,
    output reg               s_axi_bvalid,
    input  wire              s_axi_bready,

    input  wire [ADDR_W-1:0] s_axi_araddr,
    input  wire              s_axi_arvalid,
    output reg               s_axi_arready,

    output reg [31:0]        s_axi_rdata,
    output reg [1:0]         s_axi_rresp,
    output reg               s_axi_rvalid,
    input  wire              s_axi_rready,

    input  wire              tob_valid,
    input  wire              tob_changed,
    input  wire              crossed_book,
    input  wire              parse_error,
    input  wire [PRICE_W-1:0] best_bid_price,
    input  wire [QTY_W-1:0]  best_bid_qty,
    input  wire [PRICE_W-1:0] best_ask_price,
    input  wire [QTY_W-1:0]  best_ask_qty,
    input  wire [PRICE_W-1:0] spread,
    input  wire [63:0]        msg_count
);

    localparam [5:0] REG_STATUS       = 6'h00;
    localparam [5:0] REG_TOB_CHANGED  = 6'h04;
    localparam [5:0] REG_MSG_CNT_LO   = 6'h08;
    localparam [5:0] REG_MSG_CNT_HI   = 6'h0C;
    localparam [5:0] REG_BID_PRICE_LO = 6'h10;
    localparam [5:0] REG_BID_PRICE_HI = 6'h14;
    localparam [5:0] REG_BID_QTY      = 6'h18;
    localparam [5:0] REG_ASK_PRICE_LO = 6'h1C;
    localparam [5:0] REG_ASK_PRICE_HI = 6'h20;
    localparam [5:0] REG_ASK_QTY      = 6'h24;
    localparam [5:0] REG_SPREAD_LO    = 6'h28;
    localparam [5:0] REG_SPREAD_HI    = 6'h2C;

    // -----------------------------------------------------------------------
    // Write channel — tracks aw_active, wr_addr, handshake signals
    // -----------------------------------------------------------------------
    reg               aw_active;
    reg [ADDR_W-1:0]  wr_addr;

    // write_clear_parse_error: combinational signal — true when the CPU
    // writes bit 2 of STATUS to clear the parse_error latch.
    wire write_clear_parse = (s_axi_wvalid && aw_active && !s_axi_wready &&
                              wr_addr[5:0] == REG_STATUS && s_axi_wdata[2]);

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_bvalid  <= 1'b0;
            s_axi_bresp   <= 2'b00;
            aw_active     <= 1'b0;
            wr_addr       <= {ADDR_W{1'b0}};
        end else begin
            if (s_axi_awvalid && !aw_active) begin
                s_axi_awready <= 1'b1;
                wr_addr       <= s_axi_awaddr;
                aw_active     <= 1'b1;
            end else begin
                s_axi_awready <= 1'b0;
            end

            if (s_axi_wvalid && aw_active && !s_axi_wready) begin
                s_axi_wready <= 1'b1;
            end else begin
                s_axi_wready <= 1'b0;
            end

            if (s_axi_wready && !s_axi_bvalid) begin
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00;
            end

            if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
                aw_active    <= 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Read channel — drives s_axi_r* and signals read_tob_changed
    // -----------------------------------------------------------------------

    // read_tob_changed: combinational — true when CPU reads TOB_CHANGED register
    wire read_tob_changed = (s_axi_arvalid && !s_axi_rvalid &&
                             s_axi_araddr[5:0] == REG_TOB_CHANGED);

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rresp   <= 2'b00;
            s_axi_rdata   <= 32'h0;
        end else begin
            if (s_axi_arvalid && !s_axi_rvalid) begin
                s_axi_arready <= 1'b1;
                s_axi_rvalid  <= 1'b1;
                s_axi_rresp   <= 2'b00;

                case (s_axi_araddr[5:0])
                    REG_STATUS:       s_axi_rdata <= {29'h0, parse_error_latch,
                                                      crossed_book, tob_valid};
                    REG_TOB_CHANGED:  s_axi_rdata <= {31'h0, tob_changed_latch};
                    REG_MSG_CNT_LO:   s_axi_rdata <= msg_count[31:0];
                    REG_MSG_CNT_HI:   s_axi_rdata <= msg_count[63:32];
                    REG_BID_PRICE_LO: s_axi_rdata <= best_bid_price[31:0];
                    REG_BID_PRICE_HI: s_axi_rdata <= best_bid_price[63:32];
                    REG_BID_QTY:      s_axi_rdata <= best_bid_qty[31:0];
                    REG_ASK_PRICE_LO: s_axi_rdata <= best_ask_price[31:0];
                    REG_ASK_PRICE_HI: s_axi_rdata <= best_ask_price[63:32];
                    REG_ASK_QTY:      s_axi_rdata <= best_ask_qty[31:0];
                    REG_SPREAD_LO:    s_axi_rdata <= spread[31:0];
                    REG_SPREAD_HI:    s_axi_rdata <= spread[63:32];
                    default:          s_axi_rdata <= 32'hDEADBEEF;
                endcase
            end else begin
                s_axi_arready <= 1'b0;
            end

            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
        end
    end

    // -----------------------------------------------------------------------
    // tob_changed_latch — SINGLE always block (set + clear in one place)
    //   Set  : when tob_changed input pulses from the order book engine
    //   Clear: when the CPU reads the TOB_CHANGED register
    // Priority: clear wins over set on the same cycle (safe: pulses are rare)
    // -----------------------------------------------------------------------
    reg tob_changed_latch;

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            tob_changed_latch <= 1'b0;
        end else if (read_tob_changed) begin
            tob_changed_latch <= 1'b0;  // clear on read (highest priority)
        end else if (tob_changed) begin
            tob_changed_latch <= 1'b1;  // set on pulse
        end
    end

    // -----------------------------------------------------------------------
    // parse_error_latch — SINGLE always block (set + clear in one place)
    //   Set  : when parse_error input pulses from the parser
    //   Clear: when the CPU writes bit 2 of STATUS register
    // -----------------------------------------------------------------------
    reg parse_error_latch;

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            parse_error_latch <= 1'b0;
        end else if (write_clear_parse) begin
            parse_error_latch <= 1'b0;  // clear on STATUS write
        end else if (parse_error) begin
            parse_error_latch <= 1'b1;  // set on pulse
        end
    end

endmodule
