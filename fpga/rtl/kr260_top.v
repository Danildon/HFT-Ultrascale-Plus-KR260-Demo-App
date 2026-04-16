// kr260_top.v
// Board top level for Kria KR260 — plain Verilog (IEEE 1364-2001)
// Updated: adds msg_framer between s_axis input and market_data_parser.
// The framer converts the DMA's continuous byte stream into properly
// framed messages (one tlast per message) that the parser expects.

`timescale 1ns/1ps

module kr260_top #(
    parameter N_LEVELS = 8,
    parameter PRICE_W  = 64,
    parameter QTY_W    = 32,
    parameter TS_W     = 64
)(
    // ---------------------------------------------------------------------
    // Clocks / Reset
    // ---------------------------------------------------------------------
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 pl_clk1 CLK" *)
    input  wire        pl_clk1,

    input  wire        pl_clk0,
    input  wire        pl_resetn0,

    // ---------------------------------------------------------------------
    // AXI4-Lite slave
    // ---------------------------------------------------------------------
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    input  wire        s_axi_aclk,

    input  wire        s_axi_aresetn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWADDR" *)
    input  wire [5:0]  s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWVALID" *)
    input  wire        s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWREADY" *)
    output wire        s_axi_awready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WDATA" *)
    input  wire [31:0] s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WSTRB" *)
    input  wire [3:0]  s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WVALID" *)
    input  wire        s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WREADY" *)
    output wire        s_axi_wready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BRESP" *)
    output wire [1:0]  s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BVALID" *)
    output wire        s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BREADY" *)
    input  wire        s_axi_bready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARADDR" *)
    input  wire [5:0]  s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARVALID" *)
    input  wire        s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARREADY" *)
    output wire        s_axi_arready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RDATA" *)
    output wire [31:0] s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RRESP" *)
    output wire [1:0]  s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RVALID" *)
    output wire        s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RREADY" *)
    input  wire        s_axi_rready,

    // ---------------------------------------------------------------------
    // AXI4-Stream input
    // ---------------------------------------------------------------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TDATA" *)
    input  wire [7:0]  s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TVALID" *)
    input  wire        s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TLAST" *)
    input  wire        s_axis_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis TREADY" *)
    output wire        s_axis_tready,

    output wire		   pl_led_0,
    output wire		   pl_led_1,
    output wire		   pl_led_2,
    output wire		   pl_led_3
);

    // -----------------------------------------------------------------------
    // Reset synchroniser
    // -----------------------------------------------------------------------
    reg rst_n_s1, rst_n_sync;

    always @(posedge pl_clk1 or negedge pl_resetn0) begin
        if (!pl_resetn0) begin
            rst_n_s1   <= 1'b0;
            rst_n_sync <= 1'b0;
        end else begin
            rst_n_s1   <= 1'b1;
            rst_n_sync <= rst_n_s1;
        end
    end

    // -----------------------------------------------------------------------
    // msg_framer: converts DMA byte stream into parser-ready framed messages
    // -----------------------------------------------------------------------
    wire [7:0] framed_tdata;
    wire       framed_tvalid;
    wire       framed_tlast;
    wire       framed_tready;

    msg_framer u_framer (
        .clk       (pl_clk1),
        .rst_n     (rst_n_sync),
        .s_tdata   (s_axis_tdata),
        .s_tvalid  (s_axis_tvalid),
        .s_tready  (s_axis_tready),
        .m_tdata   (framed_tdata),
        .m_tvalid  (framed_tvalid),
        .m_tlast   (framed_tlast),
        .m_tready  (framed_tready)
    );

    // -----------------------------------------------------------------------
    // Market data parser (3-stage pipeline, pl_clk1 domain)
    // -----------------------------------------------------------------------
    wire              parsed_valid;
    wire [3:0]        parsed_msg_type;
    wire [TS_W-1:0]   parsed_ts;
    wire [63:0]       parsed_ref;
    wire              parsed_side;
    wire [QTY_W-1:0]  parsed_qty;
    wire [PRICE_W-1:0] parsed_price;
    wire              parsed_error;

    market_data_parser #(
        .PRICE_W (PRICE_W),
        .QTY_W   (QTY_W),
        .TS_W    (TS_W)
    ) u_parser (
        .clk          (pl_clk1),
        .rst_n        (rst_n_sync),
        .s_tdata      (framed_tdata),
        .s_tvalid     (framed_tvalid),
        .s_tlast      (framed_tlast),
        .s_tready     (framed_tready),
        .out_valid    (parsed_valid),
        .out_msg_type (parsed_msg_type),
        .out_timestamp(parsed_ts),
        .out_order_ref(parsed_ref),
        .out_side     (parsed_side),
        .out_quantity (parsed_qty),
        .out_price    (parsed_price),
        .out_error    (parsed_error)
    );

    // -----------------------------------------------------------------------
    // Order book engine
    // -----------------------------------------------------------------------
    wire              tob_valid_dp;
    wire [PRICE_W-1:0] best_bid_price_dp;
    wire [QTY_W-1:0]  best_bid_qty_dp;
    wire [PRICE_W-1:0] best_ask_price_dp;
    wire [QTY_W-1:0]  best_ask_qty_dp;
    wire [PRICE_W-1:0] spread_dp;
    wire [TS_W-1:0]   last_ts_dp;
    wire              tob_changed_dp;
    wire              crossed_dp;

    order_book_engine #(
        .N_LEVELS (N_LEVELS),
        .PRICE_W  (PRICE_W),
        .QTY_W    (QTY_W),
        .TS_W     (TS_W)
    ) u_engine (
        .clk            (pl_clk1),
        .rst_n          (rst_n_sync),
        .in_valid       (parsed_valid),
        .in_msg_type    (parsed_msg_type),
        .in_side        (parsed_side),
        .in_order_ref   (parsed_ref),
        .in_quantity    (parsed_qty),
        .in_price       (parsed_price),
        .in_timestamp   (parsed_ts),
        .tob_valid      (tob_valid_dp),
        .best_bid_price (best_bid_price_dp),
        .best_bid_qty   (best_bid_qty_dp),
        .best_ask_price (best_ask_price_dp),
        .best_ask_qty   (best_ask_qty_dp),
        .spread         (spread_dp),
        .last_update_ts (last_ts_dp),
        .tob_changed    (tob_changed_dp),
        .crossed_book   (crossed_dp)
    );

    // -----------------------------------------------------------------------
    // Message counter
    // -----------------------------------------------------------------------
    reg [63:0] msg_count_dp;

    always @(posedge pl_clk1 or negedge rst_n_sync) begin
        if (!rst_n_sync)
            msg_count_dp <= 64'h0;
        else if (parsed_valid)
            msg_count_dp <= msg_count_dp + 1'b1;
    end

    // -----------------------------------------------------------------------
    // CDC: pl_clk1 → s_axi_aclk (2-FF synchronisers on single-bit signals)
    // -----------------------------------------------------------------------
    reg tob_changed_axi_s1, tob_changed_axi;
    reg parse_error_axi_s1, parse_error_axi;
    reg crossed_axi_s1,     crossed_axi;
    reg tob_valid_axi_s1,   tob_valid_axi;

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            {tob_changed_axi, tob_changed_axi_s1} <= 2'b00;
            {parse_error_axi, parse_error_axi_s1} <= 2'b00;
            {crossed_axi,     crossed_axi_s1}     <= 2'b00;
            {tob_valid_axi,   tob_valid_axi_s1}   <= 2'b00;
        end else begin
            {tob_changed_axi, tob_changed_axi_s1} <= {tob_changed_axi_s1, tob_changed_dp};
            {parse_error_axi, parse_error_axi_s1} <= {parse_error_axi_s1, parsed_error};
            {crossed_axi,     crossed_axi_s1}     <= {crossed_axi_s1,     crossed_dp};
            {tob_valid_axi,   tob_valid_axi_s1}   <= {tob_valid_axi_s1,   tob_valid_dp};
        end
    end

    reg [PRICE_W-1:0] best_bid_price_axi;
    reg [QTY_W-1:0]   best_bid_qty_axi;
    reg [PRICE_W-1:0] best_ask_price_axi;
    reg [QTY_W-1:0]   best_ask_qty_axi;
    reg [PRICE_W-1:0] spread_axi;
    reg [63:0]        msg_count_axi;

    always @(posedge s_axi_aclk) begin
        if (tob_changed_axi) begin
            best_bid_price_axi <= best_bid_price_dp;
            best_bid_qty_axi   <= best_bid_qty_dp;
            best_ask_price_axi <= best_ask_price_dp;
            best_ask_qty_axi   <= best_ask_qty_dp;
            spread_axi         <= spread_dp;
        end
        msg_count_axi <= msg_count_dp;
    end

    // -----------------------------------------------------------------------
    // AXI4-Lite slave (TOB registers)
    // -----------------------------------------------------------------------
    tob_axi_lite #(
        .PRICE_W (PRICE_W),
        .QTY_W   (QTY_W),
        .TS_W    (TS_W)
    ) u_axi (
        .s_axi_aclk     (s_axi_aclk),
        .s_axi_aresetn  (s_axi_aresetn),
        .s_axi_awaddr   (s_axi_awaddr),
        .s_axi_awvalid  (s_axi_awvalid),
        .s_axi_awready  (s_axi_awready),
        .s_axi_wdata    (s_axi_wdata),
        .s_axi_wstrb    (s_axi_wstrb),
        .s_axi_wvalid   (s_axi_wvalid),
        .s_axi_wready   (s_axi_wready),
        .s_axi_bresp    (s_axi_bresp),
        .s_axi_bvalid   (s_axi_bvalid),
        .s_axi_bready   (s_axi_bready),
        .s_axi_araddr   (s_axi_araddr),
        .s_axi_arvalid  (s_axi_arvalid),
        .s_axi_arready  (s_axi_arready),
        .s_axi_rdata    (s_axi_rdata),
        .s_axi_rresp    (s_axi_rresp),
        .s_axi_rvalid   (s_axi_rvalid),
        .s_axi_rready   (s_axi_rready),
        .tob_valid      (tob_valid_axi),
        .tob_changed    (tob_changed_axi),
        .crossed_book   (crossed_axi),
        .parse_error    (parse_error_axi),
        .best_bid_price (best_bid_price_axi),
        .best_bid_qty   (best_bid_qty_axi),
        .best_ask_price (best_ask_price_axi),
        .best_ask_qty   (best_ask_qty_axi),
        .spread         (spread_axi),
        .msg_count      (msg_count_axi)
    );

    // -----------------------------------------------------------------------
    // LEDs
    //   [0] tob_valid        [1] tob_changed blink
    //   [2] crossed_book     [3] parse_error
    // -----------------------------------------------------------------------
    reg [23:0] stretch_cnt;
    reg        led1_stretched;
    reg        crossed_latch;
    reg        error_latch;

    always @(posedge pl_clk1 or negedge rst_n_sync) begin
        if (!rst_n_sync) begin
            stretch_cnt    <= 24'h0;
            led1_stretched <= 1'b0;
            crossed_latch  <= 1'b0;
            error_latch    <= 1'b0;
        end else begin
            if (tob_changed_dp) begin
                stretch_cnt    <= 24'hFFFFFF;
                led1_stretched <= 1'b1;
            end else if (stretch_cnt > 24'h0)
                stretch_cnt <= stretch_cnt - 1'b1;
            else
                led1_stretched <= 1'b0;

            if (crossed_dp)   crossed_latch <= 1'b1;
            if (parsed_error) error_latch   <= 1'b1;
        end
    end

    assign pl_led_0 = tob_valid_dp;
    assign pl_led_1 = led1_stretched;
    assign pl_led_2 = crossed_latch;
    assign pl_led_3 = error_latch;

endmodule
