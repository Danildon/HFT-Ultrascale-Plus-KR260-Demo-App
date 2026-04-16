// msg_framer.v
// Converts a continuous AXI4-Stream byte stream (from AXI DMA) into
// properly packetized messages for market_data_parser by inserting
// tlast at the correct position based on the message type byte.
//
// The AXI DMA sends one tlast at the end of the ENTIRE buffer. The
// parser needs tlast at the end of EACH message. This module bridges
// that gap by reading the type byte of each message and counting bytes.
//
// Supported message types and lengths:
//   'A' (0x41) = 30 bytes   Add Order
//   'U' (0x55) = 21 bytes   Order Update
//   'D' (0x44) = 17 bytes   Delete Order
//   'E' (0x45) = 21 bytes   Execute
//   'P' (0x50) = 23 bytes   Trade
//
// Framing is purely combinational-with-state: 1 cycle pipeline delay.

`timescale 1ns/1ps

module msg_framer (
    input  wire       clk,
    input  wire       rst_n,

    // Input: continuous byte stream from AXI DMA MM2S
    input  wire [7:0] s_tdata,
    input  wire       s_tvalid,
    output wire       s_tready,

    // Output: properly framed messages to market_data_parser
    output reg  [7:0] m_tdata,
    output reg        m_tvalid,
    output reg        m_tlast,
    input  wire       m_tready
);

    // Message type encodings
    localparam [7:0] TYPE_ADD    = 8'h41;  // 'A'
    localparam [7:0] TYPE_UPDATE = 8'h55;  // 'U'
    localparam [7:0] TYPE_DELETE = 8'h44;  // 'D'
    localparam [7:0] TYPE_EXEC   = 8'h45;  // 'E'
    localparam [7:0] TYPE_TRADE  = 8'h50;  // 'P'

    // -----------------------------------------------------------------------
    // State: track position within current message
    // -----------------------------------------------------------------------
    reg [5:0]  expected_len;   // total byte count for current message type
    reg [5:0]  byte_cnt;       // bytes seen in current message (1 = type byte)
    reg        in_message;     // 0 = waiting for type byte, 1 = receiving body

    // Back-pressure: pass through from downstream
    assign s_tready = m_tready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_message   <= 1'b0;
            byte_cnt     <= 6'd0;
            expected_len <= 6'd1;
            m_tvalid     <= 1'b0;
            m_tlast      <= 1'b0;
            m_tdata      <= 8'h0;
        end else begin
            // Default outputs: forward data from input, no tlast
            m_tvalid <= s_tvalid;
            m_tdata  <= s_tdata;
            m_tlast  <= 1'b0;

            if (s_tvalid && m_tready) begin
                if (!in_message) begin
                    // --------------------------------------------------------
                    // First byte of a new message: decode the type
                    // --------------------------------------------------------
                    in_message <= 1'b1;
                    byte_cnt   <= 6'd1;

                    case (s_tdata)
                        TYPE_ADD:    expected_len <= 6'd30;
                        TYPE_UPDATE: expected_len <= 6'd21;
                        TYPE_DELETE: expected_len <= 6'd17;
                        TYPE_EXEC:   expected_len <= 6'd21;
                        TYPE_TRADE:  expected_len <= 6'd23;
                        default:     expected_len <= 6'd1;   // skip unknown
                    endcase

                    // A 1-byte message (unknown type) ends on the type byte
                    if (s_tdata != TYPE_ADD    &&
                        s_tdata != TYPE_UPDATE &&
                        s_tdata != TYPE_DELETE &&
                        s_tdata != TYPE_EXEC   &&
                        s_tdata != TYPE_TRADE) begin
                        m_tlast    <= 1'b1;
                        in_message <= 1'b0;
                        byte_cnt   <= 6'd0;
                    end
                end else begin
                    // --------------------------------------------------------
                    // Subsequent bytes: count toward expected length
                    // --------------------------------------------------------
                    byte_cnt <= byte_cnt + 1'b1;

                    if (byte_cnt == (expected_len - 1'b1)) begin
                        // This is the last byte of the message
                        m_tlast    <= 1'b1;
                        in_message <= 1'b0;
                        byte_cnt   <= 6'd0;
                    end
                end
            end
        end
    end

endmodule
