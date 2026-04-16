// market_data_parser.v
// Pipelined binary market-data frame parser — plain Verilog (IEEE 1364-2001)
//
// Accepts a byte-stream (AXI4-Stream), accumulates bytes into a 30-byte
// shift register, and on s_tlast decodes the frame into output fields.
// 3-stage pipeline: 3 clock cycles from last byte in to out_valid.

`timescale 1ns/1ps

module market_data_parser #(
    parameter DATA_W  = 8,
    parameter PRICE_W = 64,
    parameter QTY_W   = 32,
    parameter TS_W    = 64
)(
    input  wire              clk,
    input  wire              rst_n,

    // AXI4-Stream input
    input  wire [DATA_W-1:0] s_tdata,
    input  wire              s_tvalid,
    input  wire              s_tlast,
    output wire              s_tready,

    // Decoded output — valid for one clock when out_valid is asserted
    output reg               out_valid,
    output reg [3:0]         out_msg_type,
    output reg [TS_W-1:0]    out_timestamp,
    output reg [63:0]        out_order_ref,
    output reg               out_side,      // 0=Bid, 1=Ask
    output reg [QTY_W-1:0]   out_quantity,
    output reg [PRICE_W-1:0] out_price,
    output reg               out_error
);

    // -----------------------------------------------------------------------
    // Message type encodings
    // -----------------------------------------------------------------------
    localparam [7:0] MSG_ADD    = 8'h41;  // 'A'
    localparam [7:0] MSG_UPDATE = 8'h55;  // 'U'
    localparam [7:0] MSG_DELETE = 8'h44;  // 'D'
    localparam [7:0] MSG_EXEC   = 8'h45;  // 'E'
    localparam [7:0] MSG_TRADE  = 8'h50;  // 'P'

    localparam [3:0] TYPE_ADD    = 4'd0;
    localparam [3:0] TYPE_UPDATE = 4'd1;
    localparam [3:0] TYPE_DELETE = 4'd2;
    localparam [3:0] TYPE_EXEC   = 4'd3;
    localparam [3:0] TYPE_TRADE  = 4'd4;
    localparam [3:0] TYPE_UNKN   = 4'd15;

    localparam MAX_FRAME = 30;  // maximum frame length in bytes

    // -----------------------------------------------------------------------
    // Stage 1 — shift register (240 bits = 30 bytes)
    // New byte enters at LSB [7:0], previous bytes shift up.
    // After all bytes arrive, byte 0 is at [239:232].
    // -----------------------------------------------------------------------
    reg [MAX_FRAME*8-1:0] frame_sr;
    reg [5:0]              byte_cnt;

    assign s_tready = 1'b1;   // always ready — no back-pressure

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_sr <= {(MAX_FRAME*8){1'b0}};
            byte_cnt <= 6'd0;
        end else if (s_tvalid) begin
            frame_sr <= {frame_sr[MAX_FRAME*8-9:0], s_tdata};
            byte_cnt <= s_tlast ? 6'd0 : byte_cnt + 1'b1;
        end
    end

    // -----------------------------------------------------------------------
    // Stage 1 → 2 pipeline register
    // -----------------------------------------------------------------------
    reg [MAX_FRAME*8-1:0] p1_frame;
    reg [5:0]              p1_byte_cnt;
    reg                    p1_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p1_valid    <= 1'b0;
            p1_byte_cnt <= 6'd0;
            p1_frame    <= {(MAX_FRAME*8){1'b0}};
        end else begin
            p1_valid    <= s_tvalid && s_tlast;
            p1_byte_cnt <= byte_cnt + 1'b1;
            p1_frame    <= {frame_sr[MAX_FRAME*8-9:0], s_tdata};
        end
    end

    // -----------------------------------------------------------------------
    // Stage 2 — latch raw fields from fixed bit positions
    // Byte 0 = p1_frame[239:232], byte N = p1_frame[239-N*8 : 232-N*8]
    // -----------------------------------------------------------------------
    reg [7:0]  p2_type;
    reg [63:0] p2_ts;
    reg [63:0] p2_ref;
    reg [7:0]  p2_side_byte;
    reg [31:0] p2_qty;
    reg [63:0] p2_price;
    reg [5:0]  p2_byte_cnt;
    reg        p2_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p2_valid     <= 1'b0;
            p2_byte_cnt  <= 6'd0;
            p2_type      <= 8'h0;
            p2_ts        <= 64'h0;
            p2_ref       <= 64'h0;
            p2_side_byte <= 8'h0;
            p2_qty       <= 32'h0;
            p2_price     <= 64'h0;
        end else begin
            p2_valid     <= p1_valid;
            p2_byte_cnt  <= p1_byte_cnt;
            // Fixed byte offsets in the accumulated shift register
            p2_type      <= p1_frame[239:232];          // byte  0
            p2_ts        <= p1_frame[231:168];           // bytes 1-8
            p2_ref       <= p1_frame[167:104];           // bytes 9-16
            p2_side_byte <= p1_frame[103:96];            // byte  17
            p2_qty       <= p1_frame[95:64];             // bytes 18-21
            p2_price     <= p1_frame[63:0];              // bytes 22-29
        end
    end

    // -----------------------------------------------------------------------
    // Stage 3 — byte-swap + decode → output registers
    // Byte-swap is pure combinational wiring (no logic gates, just rewiring).
    // -----------------------------------------------------------------------

    // Big-endian → little-endian byte reversal via concatenation
    wire [63:0] ts_le    = {p2_ts[7:0],    p2_ts[15:8],   p2_ts[23:16],  p2_ts[31:24],
                             p2_ts[39:32],  p2_ts[47:40],  p2_ts[55:48],  p2_ts[63:56]};
    wire [63:0] ref_le   = {p2_ref[7:0],   p2_ref[15:8],  p2_ref[23:16], p2_ref[31:24],
                             p2_ref[39:32], p2_ref[47:40], p2_ref[55:48], p2_ref[63:56]};
    wire [31:0] qty_le   = {p2_qty[7:0],   p2_qty[15:8],  p2_qty[23:16], p2_qty[31:24]};
    wire [63:0] price_le = {p2_price[7:0],    p2_price[15:8],  p2_price[23:16],
                             p2_price[31:24],  p2_price[39:32], p2_price[47:40],
                             p2_price[55:48],  p2_price[63:56]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid     <= 1'b0;
            out_msg_type  <= TYPE_UNKN;
            out_timestamp <= {TS_W{1'b0}};
            out_order_ref <= 64'h0;
            out_side      <= 1'b0;
            out_quantity  <= {QTY_W{1'b0}};
            out_price     <= {PRICE_W{1'b0}};
            out_error     <= 1'b0;
        end else begin
            out_valid     <= p2_valid;
            out_error     <= 1'b0;
            out_timestamp <= ts_le;
            out_order_ref <= ref_le;
            out_side      <= (p2_side_byte == 8'h53); // 'S' = Ask = 1
            out_quantity  <= qty_le;
            out_price     <= price_le;

            if (p2_valid) case (p2_type)
                MSG_ADD: begin
                    out_msg_type <= TYPE_ADD;
                    if (p2_byte_cnt < 6'd30) out_error <= 1'b1;
                end
                MSG_UPDATE: begin
                    out_msg_type <= TYPE_UPDATE;
                    if (p2_byte_cnt < 6'd21) out_error <= 1'b1;
                end
                MSG_DELETE: begin
                    out_msg_type <= TYPE_DELETE;
                    if (p2_byte_cnt < 6'd17) out_error <= 1'b1;
                end
                MSG_EXEC: begin
                    out_msg_type <= TYPE_EXEC;
                    if (p2_byte_cnt < 6'd21) out_error <= 1'b1;
                end
                MSG_TRADE: begin
                    out_msg_type <= TYPE_TRADE;
                    if (p2_byte_cnt < 6'd23) out_error <= 1'b1;
                end
                default: begin
                    out_msg_type <= TYPE_UNKN;
                    out_error    <= 1'b1;
                end
            endcase // if (p2_valid)
        end
    end

endmodule
