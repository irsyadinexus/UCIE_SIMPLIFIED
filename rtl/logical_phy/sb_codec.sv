// UCIe 1.0 Simplified Endpoint - sideband encoder / decoder
// Spec Chapter 6. 64-bit serial packets with a 32-UI gap.
//
// Simplified 64-bit header layout (PoC; documented in doc/PLAN.md section 4.2):
//   [4:0]    opcode
//   [7:5]    srcid
//   [10:8]   dstid
//   [18:11]  MsgInfo     (8 bits)
//   [26:19]  MsgCode     (8 bits)
//   [34:27]  MsgSubcode  (8 bits)
//   [35]     Cr
//   [36]     CP   even parity over every header bit except DP
//   [37]     DP   even parity over the data payload, 0 when there is no payload
//   [45:38]  BE
//   [50:46]  Tag
//   [51]     EP
//   [63:52]  Addr
//
// The codec is the only module that knows these bit positions; it exposes the
// parsed fields as named ports so the LTSM never touches raw header bits.
`ifndef SbCodec_SV
`define SbCodec_SV
`include "ucie_pkg.sv"

module sb_codec (
  input  logic        sbclk,         // 800 MHz sideband clock
  input  logic        sbreset_n,

  // --------------------------------------------------------------- transmit
  input  logic        tx_load,       // pulse: load a new packet
  input  logic [4:0]  tx_opcode,
  input  logic [2:0]  tx_srcid,
  input  logic [2:0]  tx_dstid,
  input  logic [7:0]  tx_msginfo,
  input  logic [7:0]  tx_msgcode,
  input  logic [7:0]  tx_msgsubcode,
  input  logic        tx_cr,
  input  logic [11:0] tx_addr,
  input  logic [7:0]  tx_be,
  input  logic [4:0]  tx_tag,
  input  logic        tx_ep,
  input  logic [63:0] tx_data_in,
  input  logic        tx_has_data,
  output logic        tx_busy,
  output logic [NC-1:0] sb_tx_data,  // serial lane toward partner
  output logic        sb_tx_valid,

  // --------------------------------------------------------------- receive
  input  logic [NC-1:0] sb_rx_data,
  input  logic        sb_rx_valid,
  output logic        rx_pkt_vld,
  output logic [4:0]  rx_opcode,
  output logic [2:0]  rx_srcid,
  output logic [2:0]  rx_dstid,
  output logic [7:0]  rx_msginfo,
  output logic [7:0]  rx_msgcode,
  output logic [7:0]  rx_msgsubcode,
  output logic        rx_cr,
  output logic [7:0]  rx_be,
  output logic [4:0]  rx_tag,
  output logic        rx_ep,
  output logic [11:0] rx_addr,
  output logic [63:0] rx_data,
  output logic        rx_cp_err,     // CP mismatch
  output logic        rx_dp_err      // DP mismatch (data payload only)
);

  import ucie_pkg::*;

  // ------------------------------------------------- header assembly (TX)
  // The concatenation must be exactly 64 bits, with a placeholder bit for CP
  // at [36] and DP at [37] so the parity can be computed over the rest.
  function automatic logic [63:0] assemble_hdr(
    logic [4:0]  op,
    logic [2:0]  sid,
    logic [2:0]  did,
    logic [7:0]  minfo,
    logic [7:0]  mcode,
    logic [7:0]  msub,
    logic        cr,
    logic [11:0] addr,
    logic [7:0]  be,
    logic [4:0]  tag,
    logic        ep
  );
    logic [63:0] hdr;
    logic        cp;
    hdr = {addr, ep, tag, be, 1'b0, 1'b0, cr, msub, mcode, minfo, did, sid, op};
    cp  = ^hdr;          // both placeholders are 0, so they do not contribute
    hdr[36] = cp;
    return hdr;
  endfunction

  // --------------------------------------------------------------- transmit
  logic [63:0]  hdr_q;
  logic [63:0]  payload_q;
  logic         has_data_q;
  logic [6:0]   bit_q;       // 0..63 within the header, then 0..63 within payload
  logic         in_gap_q;
  logic [5:0]   gap_q;
  logic         in_payload_q;
  logic         tx_busy_i;

  wire dp_calc = tx_has_data ? ^tx_data_in : 1'b0;

  always_ff @(posedge sbclk or negedge sbreset_n) begin
    if (!sbreset_n) begin
      hdr_q        <= '0;
      payload_q    <= '0;
      has_data_q   <= 1'b0;
      bit_q        <= '0;
      in_gap_q     <= 1'b0;
      in_payload_q <= 1'b0;
      gap_q        <= '0;
      sb_tx_valid  <= 1'b0;
    end else if (tx_load && !tx_busy_i) begin
      hdr_q        <= assemble_hdr(tx_opcode, tx_srcid, tx_dstid, tx_msginfo,
                                  tx_msgcode, tx_msgsubcode, tx_cr,
                                  tx_addr, tx_be, tx_tag, tx_ep);
      hdr_q[37]    <= dp_calc;      // DP is outside the CP coverage
      payload_q    <= tx_data_in;
      has_data_q   <= tx_has_data;
      bit_q        <= '0;
      in_payload_q <= 1'b0;
      in_gap_q     <= 1'b0;
      sb_tx_valid  <= 1'b1;
    end else if (sb_tx_valid) begin
      if (!in_payload_q && bit_q == 7'd63) begin
        if (has_data_q) begin
          // Header sent and a payload follows.
          bit_q        <= '0;
          in_payload_q <= 1'b1;
        end else begin
          sb_tx_valid  <= 1'b0;
          in_gap_q     <= 1'b1;
          gap_q        <= SB_GAP_UI[5:0];
        end
      end else if (in_payload_q && bit_q == 7'd63) begin
        sb_tx_valid  <= 1'b0;
        in_payload_q <= 1'b0;
        in_gap_q     <= 1'b1;
        gap_q        <= SB_GAP_UI[5:0];
      end else begin
        bit_q <= bit_q + 1'b1;
      end
    end else if (in_gap_q) begin
      if (gap_q == 6'd1) in_gap_q <= 1'b0;
      else               gap_q   <= gap_q - 1'b1;
    end
  end

  // One header/payload bit per UI, bit 0 first, else idle low. The bit select
  // is a continuous assign: iverilog 12 cannot evaluate a variable index
  // inside an always_* process.
  wire tx_bit = in_payload_q ? payload_q[bit_q] : hdr_q[bit_q];

  assign sb_tx_data = sb_tx_valid ? {NC{tx_bit}} : {NC{1'b0}};

  assign tx_busy_i = sb_tx_valid | in_gap_q;
  assign tx_busy   = tx_busy_i;

  // --------------------------------------------------------------- receive
  // Shift RIGHT so the first-arriving bit (bit 0 of the header) lands in
  // position 0, matching the transmitted word.
  logic [63:0] shift_q;
  logic [6:0]  cnt_q;
  logic        collecting_q;
  logic        hdr_done_q;
  logic [63:0] hdr_lat_q;
  logic [63:0] data_lat_q;
  logic        rx_bit;

  wire [63:0]  new_word = {rx_bit, shift_q[63:1]};

  assign rx_bit = sb_rx_data[0];

  always_ff @(posedge sbclk or negedge sbreset_n) begin
    if (!sbreset_n) begin
      shift_q      <= '0;
      cnt_q        <= '0;
      collecting_q <= 1'b0;
      hdr_done_q   <= 1'b0;
      rx_pkt_vld   <= 1'b0;
      hdr_lat_q    <= '0;
      data_lat_q   <= '0;
    end else begin
      rx_pkt_vld <= 1'b0;

      if (sb_rx_valid) begin
        if (!collecting_q) begin
          collecting_q <= 1'b1;
          // Start at 1, not 0: the first UI is counted by this cycle, so the
          // 64th header bit sees cnt_q == 63 and the 64th payload bit 127.
          cnt_q        <= 7'd1;
          shift_q      <= {rx_bit, 63'b0};
        end else begin
          cnt_q   <= cnt_q + 1'b1;
          shift_q <= new_word;
          if (cnt_q == 7'd63) begin
            hdr_lat_q  <= new_word;
            hdr_done_q <= 1'b1;
            // A payload follows only for the with-data opcode. DP cannot be
            // used here: a payload with even parity drives DP to 0, which
            // would truncate a valid packet.
            if (new_word[4:0] != SB_OP_MSG_DATA64) begin
              rx_pkt_vld   <= 1'b1;
              collecting_q <= 1'b0;
              hdr_done_q   <= 1'b0;
            end
          end else if (hdr_done_q && cnt_q == 7'd127) begin
            data_lat_q  <= new_word;
            rx_pkt_vld  <= 1'b1;
            collecting_q<= 1'b0;
            hdr_done_q  <= 1'b0;
          end
        end
      end
    end
  end

  // Field extraction from the latched header.
  assign rx_opcode    = hdr_lat_q[4:0];
  assign rx_srcid     = hdr_lat_q[7:5];
  assign rx_dstid     = hdr_lat_q[10:8];
  assign rx_msginfo   = hdr_lat_q[18:11];
  assign rx_msgcode   = hdr_lat_q[26:19];
  assign rx_msgsubcode= hdr_lat_q[34:27];
  assign rx_cr        = hdr_lat_q[35];
  assign rx_addr      = hdr_lat_q[63:52];
  assign rx_be        = hdr_lat_q[45:38];
  assign rx_tag       = hdr_lat_q[50:46];
  assign rx_ep        = hdr_lat_q[51];
  assign rx_data      = data_lat_q;

  // CP covers every header bit except DP and itself; compare against bit 36.
  wire [63:0] hdr_cp_mask = {hdr_lat_q[63:38], 2'b00, hdr_lat_q[35:0]};
  assign rx_cp_err = rx_pkt_vld && (^hdr_cp_mask != hdr_lat_q[36]);
  // DP is the even parity of the payload, 0 when there is no payload.
  assign rx_dp_err = rx_pkt_vld && hdr_lat_q[37] && (^data_lat_q != hdr_lat_q[37]);

endmodule

`endif
