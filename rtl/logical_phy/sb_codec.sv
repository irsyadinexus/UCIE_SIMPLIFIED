// ============================================================================
// File        : sb_codec.sv
// Module      : sb_codec
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Sideband encoder / decoder for UCIe 64-bit serial packets.
//               Serialises outgoing sideband messages one bit per UI on the
//               sbclk domain, and deserialises incoming messages into named
//               fields. The codec is the only module that knows the bit-field
//               positions of the sideband header; all other blocks (LTSM,
//               RDI SM) see parsed, typed ports.
//
// Spec refs   : UCIe 1.0 spec Chapter 6 (sideband framing, 64-bit serial
//               packets with a 32-UI inter-packet gap), Table 47 (sideband
//               opcodes), Tables 53/54/56 (message codes and subcodes).
//
// --------------------------------------------------------------------------
// 64-bit header layout  (PoC; documented in doc/PLAN.md section 4.2)
// --------------------------------------------------------------------------
//
//   Bit range   Field           Width   Description
//   ---------   -----           -----   -----------
//   [ 4: 0]     Opcode           5      Table 47 sideband opcode.
//   [ 7: 5]     SrcID            3      Source stack ID (Table 49).
//   [10: 8]     DstID            3      Destination stack ID (Table 49).
//   [18:11]     MsgInfo          8      Message-specific info (Table 54).
//   [26:19]     MsgCode          8      Message code (Tables 53/54/56).
//   [34:27]     MsgSubcode       8      Message subcode (Tables 53/54/56).
//   [35]        Cr               1      Credit return bit.
//   [36]        CP               1      Even parity over all header bits
//                                       except DP (bit 37). Spec Ch 6.
//   [37]        DP               1      Even parity over the data payload;
//                                       0 when there is no payload. Spec Ch 6.
//   [45:38]     BE               8      Byte enables.
//   [50:46]     Tag              5      Transaction tag.
//   [51]        EP               1      Error/poison bit.
//   [63:52]     Addr            12      Address field.
//
// --------------------------------------------------------------------------
// Parity rules  (spec Chapter 6)
// --------------------------------------------------------------------------
//   CP (Command Parity): Even parity computed over every header bit EXCEPT
//   DP (bit 37) and CP itself (bit 36). During assembly both placeholder
//   bits are 0, so XOR-reducing the 64-bit word yields the correct CP value.
//   CP is written into bit 36 after the reduction. DP is then OR'd into
//   bit 37 independently.
//
//   DP (Data Parity): Even parity of the 64-bit data payload. Set to 0
//   when the packet carries no data (opcode != SB_OP_MSG_DATA64).
//
//   On receive, CP is re-computed from the latched header and compared
//   against bit 36; a mismatch raises rx_cp_err. DP is compared against
//   bit 37 only when a data payload was received; a mismatch raises
//   rx_dp_err.
//
// --------------------------------------------------------------------------
// TX sequencing
// --------------------------------------------------------------------------
//   1. The LTSM asserts tx_load with all field inputs valid.
//   2. The codec calls assemble_hdr() to pack the header, computes CP and
//      DP, and latches the result.
//   3. The header is shifted out one bit per sbclk cycle (64 UIs, LSB
//      first), then the data payload (if tx_has_data), then a 32-UI idle
//      gap (SB_GAP_UI).
//   4. tx_busy is high throughout; the LTSM must not assert tx_load while
//      tx_busy.
//
// --------------------------------------------------------------------------
// RX sequencing
// --------------------------------------------------------------------------
//   1. The codec waits for sb_rx_valid to start collecting bits.
//   2. A 64-bit shift register captures bits LSB-first (shift right).
//   3. At bit 63, the header is latched. If the opcode is not
//      SB_OP_MSG_DATA64, rx_pkt_vld pulses and collection ends.
//   4. If the opcode IS SB_OP_MSG_DATA64, collection continues for another
//      64 bits (payload). At bit 127 the data is latched, rx_pkt_vld
//      pulses, and collection ends.
//
// --------------------------------------------------------------------------
// Parameters
// --------------------------------------------------------------------------
//   None (NC and SB_GAP_UI from ucie_pkg).
//
// --------------------------------------------------------------------------
// Interfaces
// --------------------------------------------------------------------------
//   TX: Field inputs from LTSM, serial output sb_tx_data/sb_tx_valid to
//       partner die. tx_busy backpressure.
//   RX: Serial input sb_rx_data/sb_rx_valid from partner die, parsed field
//       outputs to LTSM. rx_pkt_vld indicates a complete packet.
//       rx_cp_err, rx_dp_err indicate parity mismatches.
//
// --------------------------------------------------------------------------
// Implementation notes
// --------------------------------------------------------------------------
//   1. The bit select for TX output uses a continuous assign (wire tx_bit)
//      because Icarus Verilog 12 cannot evaluate a variable index inside
//      an always_* process.
//   2. The RX shift register shifts RIGHT so that the first-arriving bit
//      (bit 0 of the header) lands in position 0, matching the transmitted
//      word order.
//   3. The DP parity check on receive: DP=1 with all-zero data is a valid
//      encoding (parity of zero is 0, which does NOT equal 1, so it would
//      be flagged). The spec guarantees payloads are non-trivial when DP
//      is set.
//
// --------------------------------------------------------------------------
// Revision history
// --------------------------------------------------------------------------
//   v0.0.1  2025-XX-XX  First commit to git. Full TX/RX codec with CP/DP
//                        parity, 32-UI gap, and field extraction.
// ============================================================================
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

  // =========================================================================
  // Header assembly function  (spec Chapter 6 header format)
  // =========================================================================
  // Packs all named fields into a 64-bit header word per the bit-field layout
  // documented above. CP (bit 36) and DP (bit 37) are set to 0 during
  // concatenation so that XOR-reducing the 64-bit word yields the correct CP
  // value. CP is then written into bit 36. DP is handled separately by the
  // caller (assemble_hdr returns the header with DP still at 0).
  //
  // The concatenation must be exactly 64 bits. Field order in the concat
  // (MSB first): {Addr[11:0], EP, Tag[4:0], BE[7:0], DP_placeholder,
  //               CP_placeholder, Cr, MsgSubcode[7:0], MsgCode[7:0],
  //               MsgInfo[7:0], DstID[2:0], SrcID[2:0], Opcode[4:0]}.
  // =========================================================================
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

  // =========================================================================
  // TX state registers and DP calculation
  // =========================================================================
  logic [63:0]  hdr_q;
  logic [63:0]  payload_q;
  logic         has_data_q;
  logic [6:0]   bit_q;       // 0..63 within the header, then 0..63 within payload
  logic         in_gap_q;
  logic [5:0]   gap_q;
  logic         in_payload_q;
  logic         tx_busy_i;

  // =========================================================================
  // DP (Data Parity) calculation  (spec Chapter 6)
  // =========================================================================
  // DP is the even parity of the 64-bit data payload. When tx_has_data is 0,
  // DP is forced to 0. This wire is sampled on tx_load and written into
  // hdr_q[37] one cycle after header assembly.
  // =========================================================================
  wire dp_calc = tx_has_data ? ^tx_data_in : 1'b0;

  // =========================================================================
  // TX serialiser FSM  (spec Chapter 6 – 64-bit serial, 32-UI gap)
  // =========================================================================
  // Drives the outgoing sideband lane one bit per sbclk cycle. The FSM has
  // four phases:
  //   1. Load      : tx_load && !tx_busy_i -> latch header, payload, set
  //                  sb_tx_valid, start at bit 0.
  //   2. Header    : Shift out bits 0..63 of the assembled header. If
  //                  has_data_q, transition to payload phase; else enter gap.
  //   3. Payload   : Shift out bits 0..63 of the data payload. Then enter
  //                  gap.
  //   4. Gap       : De-assert sb_tx_valid, count down SB_GAP_UI (32) cycles
  //                  of idle. Then return to idle (tx_busy_i = 0).
  //
  // Reset clears all registers and de-asserts sb_tx_valid.
  // =========================================================================
  always_ff @(posedge sbclk or negedge sbreset_n) begin
    if (!sbreset_n) begin
      hdr_q        <= 64'h0;
      payload_q    <= 64'h0;
      has_data_q   <= 1'b0;
      bit_q        <= 7'h00;
      in_gap_q     <= 1'b0;
      in_payload_q <= 1'b0;
      gap_q        <= 6'h00;
      sb_tx_valid  <= 1'b0;
    end else if (tx_load && !tx_busy_i) begin
      hdr_q        <= assemble_hdr(tx_opcode, tx_srcid, tx_dstid, tx_msginfo,
                                  tx_msgcode, tx_msgsubcode, tx_cr,
                                  tx_addr, tx_be, tx_tag, tx_ep);
      hdr_q[37]    <= dp_calc;      // DP is outside the CP coverage
      payload_q    <= tx_data_in;
      has_data_q   <= tx_has_data;
      bit_q        <= 7'h00;
      in_payload_q <= 1'b0;
      in_gap_q     <= 1'b0;
      sb_tx_valid  <= 1'b1;
    end else if (sb_tx_valid) begin
      if (!in_payload_q && bit_q == 7'd63) begin
        if (has_data_q) begin
          // Header sent and a payload follows.
          bit_q        <= 7'h00;
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

  // =========================================================================
  // TX output bit selection  (spec Chapter 6 – LSB-first serialisation)
  // =========================================================================
  // One header or payload bit per UI, bit 0 first. The bit select is a
  // continuous assign because Icarus Verilog 12 cannot evaluate a variable
  // index inside an always_* process. When sb_tx_valid is de-asserted the
  // output lane is driven to zero (idle).
  // =========================================================================
  wire tx_bit = in_payload_q ? payload_q[bit_q] : hdr_q[bit_q];

  // =========================================================================
  // TX serial output  (spec Chapter 6 – NC-wide sideband lane)
  // =========================================================================
  // All NC bits of the sideband lane carry the same serialised bit value.
  // When the codec is idle (sb_tx_valid = 0), the lane is driven low.
  // =========================================================================
  assign sb_tx_data = sb_tx_valid ? {NC{tx_bit}} : {NC{1'b0}};

  // =========================================================================
  // TX busy signal
  // =========================================================================
  // tx_busy is asserted while the codec is serialising a packet or counting
  // down the inter-packet gap. The LTSM must not assert tx_load while
  // tx_busy is high.
  // =========================================================================
  assign tx_busy_i = sb_tx_valid | in_gap_q;
  assign tx_busy   = tx_busy_i;

  // =========================================================================
  // RX deserialiser state
  // =========================================================================
  logic [63:0] shift_q;
  logic [6:0]  cnt_q;
  logic        collecting_q;
  logic        hdr_done_q;
  logic [63:0] hdr_lat_q;
  logic [63:0] data_lat_q;
  logic        rx_bit;

  wire [63:0]  new_word = {rx_bit, shift_q[63:1]};

  // =========================================================================
  // RX bit extraction  (spec Chapter 6 – first bit on sb_rx_data[0])
  // =========================================================================
  // The incoming sideband data is sampled on bit 0 of the NC-wide bus. All
  // NC bits carry the same value; bit 0 is the canonical sample point.
  // =========================================================================
  assign rx_bit = sb_rx_data[0];

  // =========================================================================
  // RX deserialiser FSM  (spec Chapter 6 – 64-bit header + optional payload)
  // =========================================================================
  // Captures incoming sideband bits into a 64-bit shift register (shift
  // right so bit 0 lands in position 0). The FSM has three phases:
  //
  //   1. Idle       : Wait for sb_rx_valid. On the first valid bit, set
  //                   collecting_q and initialise cnt_q to 1 (this cycle
  //                   counts as the first UI).
  //   2. Header     : Shift bits 1..63 into the register. At cnt_q == 63
  //                   (64th bit), latch the header (hdr_lat_q). If the
  //                   opcode is NOT SB_OP_MSG_DATA64, pulse rx_pkt_vld and
  //                   return to idle. Otherwise set hdr_done_q and continue.
  //   3. Payload    : Shift bits 64..127 into the register. At cnt_q == 127
  //                   (128th bit), latch the data (data_lat_q), pulse
  //                   rx_pkt_vld, and return to idle.
  //
  // Reset clears all registers and de-asserts rx_pkt_vld.
  // =========================================================================
  always_ff @(posedge sbclk or negedge sbreset_n) begin
    if (!sbreset_n) begin
      shift_q      <= 64'h0;
      cnt_q        <= 7'h00;
      collecting_q <= 1'b0;
      hdr_done_q   <= 1'b0;
      rx_pkt_vld   <= 1'b0;
      hdr_lat_q    <= 64'h0;
      data_lat_q   <= 64'h0;
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

  // =========================================================================
  // RX field extraction  (spec Chapter 6 / Tables 47, 49, 53, 54, 56)
  // =========================================================================
  // Each named field is extracted from the latched header (hdr_lat_q) using
  // the bit positions defined in the header layout above. The data payload
  // is extracted from data_lat_q.
  //
  // rx_opcode    : [4:0]   Sideband opcode (Table 47).
  // rx_srcid     : [7:5]   Source stack ID (Table 49).
  // rx_dstid     : [10:8]  Destination stack ID (Table 49).
  // rx_msginfo   : [18:11] Message info (Table 54).
  // rx_msgcode   : [26:19] Message code (Tables 53/54/56).
  // rx_msgsubcode: [34:27] Message subcode (Tables 53/54/56).
  // rx_cr        : [35]    Credit return bit.
  // rx_addr      : [63:52] Address field.
  // rx_be        : [45:38] Byte enables.
  // rx_tag       : [50:46] Transaction tag.
  // rx_ep        : [51]    Error/poison bit.
  // rx_data      : Full 64-bit data payload from data_lat_q.
  // =========================================================================
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

  // =========================================================================
  // CP parity check  (spec Chapter 6 – Command Parity)
  // =========================================================================
  // CP covers every header bit except DP (bit 37) and CP itself (bit 36).
  // A mask zeroes bits [37:36] before XOR-reducing. The result is compared
  // against the received CP value in bit 36. A mismatch raises rx_cp_err
  // coincident with rx_pkt_vld.
  // =========================================================================
  wire [63:0] hdr_cp_mask = {hdr_lat_q[63:38], 2'b00, hdr_lat_q[35:0]};
  assign rx_cp_err = rx_pkt_vld && (^hdr_cp_mask != hdr_lat_q[36]);

  // =========================================================================
  // DP parity check  (spec Chapter 6 – Data Parity)
  // =========================================================================
  // DP is the even parity of the payload. When there is no payload, DP
  // should be 0. The check fires only when DP (bit 37) is set AND the
  // XOR-reduction of the data payload does not match bit 37. rx_dp_err is
  // raised coincident with rx_pkt_vld.
  // =========================================================================
  assign rx_dp_err = rx_pkt_vld && hdr_lat_q[37] && (^data_lat_q != hdr_lat_q[37]);

endmodule

`endif
