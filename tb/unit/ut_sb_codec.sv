// ============================================================================
// File        : ut_sb_codec.sv
// Description : Unit test for the sideband codec (sb_codec) module.
// ============================================================================
//
// PURPOSE
// -------
// This testbench exercises the sb_codec module in a transmit-to-receive serial
// loopback configuration.  It verifies round-trip serialization and
// deserialization of sideband messages, as well as parity-error detection on
// a deliberately corrupted link.
//
// Two sb_codec instances are instantiated:
//
//   u_tx  – configured as the transmitter.  The testbench drives the
//           parallel message fields (opcode, srcid, dstid, msgcode, data,
//           etc.) into u_tx, which serialises them onto its sb_tx_data /
//           sb_tx_valid outputs.
//
//   u_rx  – configured as the receiver.  Its sb_rx_data / sb_rx_valid
//           inputs are fed from u_tx's serial output (optionally through
//           a corruption mux — see below).  On reception of a complete
//           message it asserts rx_pkt_vld for one clock and presents the
//           deserialised fields.
//
// The serial link between u_tx and u_rx passes through an explicit XOR
// corruption mux controlled by the testbench signal `corrupt_en`.  When
// `corrupt_en` is high for exactly one UI the received bit pattern is
// inverted, injecting a single-bit error that the codec's parity checker
// must detect.
//
//   Spec ref: Section 6.1.2 – Packet Formats
//             (defines the header and data-parity bit positions that the
//              codec serialises/deserialises and that this test verifies)
//
//   Spec ref: Section 6.1.3 – Flow Control and Data Integrity
//             (defines the CP / DP parity check that must flag corrupted
//              packets; test 4 below validates this requirement)
//
//
// BLOCK DIAGRAM
// -------------
// The loopback topology with corruption injection is shown below.
//
//         Testbench parallel IF              Serial link
//    ┌──────────────────────┐
//    │   Stimulus fields    │
//    │  (opcode, srcid, …)  │
//    └──────────┬───────────┘
//               │  tx_load
//               ▼
//    ┌─────────────────────┐    sb_wire     ┌────────────┐   sb_wire_rx
//    │       u_tx          ├───────────────►│ corrupt_en │──────────────►┐
//    │    (sb_codec #0)    │  sb_wire_valid │   XOR mux  │              │
//    └─────────────────────┘                └────────────┘              │
//                                                                      │
//                                                              sb_rx_valid
//                                                                      │
//                                                                      ▼
//                                                      ┌──────────────────────┐
//                                                      │        u_rx          │
//                                                      │     (sb_codec #1)    │
//                                                      └──────────┬───────────┘
//                                                                 │ rx_pkt_vld
//                                                                 ▼
//                                                      ┌──────────────────────┐
//                                                      │  Snapshot & compare  │
//                                                      │   (check_fields)     │
//                                                      └──────────────────────┘
//
//
// CLOCK RATE – SIMULATION CONCESSION
// -----------------------------------
// The sideband clock (sbclk) in this testbench runs at 250 MHz (2 ns
// half-period, 4 ns period).  This is a simulation-only reduced rate chosen
// for convenience and faster simulation turn-around.  The production
// sideband signalling rate is 800 MHz as specified in Section 5.13 –
// Sideband signaling.  Because the codec logic is fully synchronous to
// sbclk with no cycle-count-dependent timing, functional correctness at
// 250 MHz implies correctness at 800 MHz; only gate-level timing closure
// is affected.
//
//   Spec ref: Section 5.13 – Sideband signaling
//             (defines the 800 MHz production sideband rate)
//
//
// STIMULUS (DIRECTED TESTS)
// -------------------------
// Four directed tests exercise increasing complexity:
//
//   Test 1 – Header-only message
//            A LinkMgmt no-data request (SB_OP_MSG_NODATA) is sent with
//            representative field values.  All deserialised header fields
//            must match the transmitted values, and neither cp_err nor
//            dp_err may be asserted.
//
//   Test 2 – Message with 64-bit payload
//            A data-bearing message (SB_OP_MSG_DATA64) is sent.  Both the
//            header and the 64-bit data word must round-trip correctly.
//            The data pattern (BEEF_DEAD_BEEF_DEAD) has odd popcount to
//            exercise the data-parity path.
//
//   Test 3 – Back-to-back packets
//            Two header-only packets are transmitted in immediate
//            succession (the second tx_load is issued as soon as tx_busy
//            deasserts after the first).  This verifies that the mandatory
//            inter-packet gap does not corrupt the following header.
//
//   Test 4 – Parity error injection via corrupt_en mux
//            A header-only packet is transmitted, but the corruption mux
//            is enabled for exactly one header UI (UI 10) during
//            serialisation.  The receiver must still deliver the packet
//            (rx_pkt_vld asserted) but with cp_err flagged HIGH, proving
//            that the parity checker detects the injected bit-flip.
//
//   Spec ref: Section 6.1.2 – Packet Formats
//             (header and data field layout exercised by tests 1-3)
//   Spec ref: Section 6.1.3 – Flow Control and Data Integrity
//             (parity error detection exercised by test 4)
//
//
// PASS CRITERIA
// -------------
// The test passes if and only if:
//   - All transmitted header / data fields match after round-trip
//     deserialisation (tests 1-3).
//   - cp_err is NOT asserted for clean transmissions (tests 1-3).
//   - cp_err IS asserted when the corruption mux flips a header bit
//     (test 4).
//   - The test completes before the 2 ms watchdog timeout.
//
//
// REVISION HISTORY
// ----------------
//   v0.0.1  2025-XX-XX  Initial creation.
//   v0.0.2  2026-09-23  Documentation: expand header, add per-block
//                        comments throughout the testbench.
//
// ============================================================================
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module ut_sb_codec;
  logic        sbclk, sbreset_n;
  logic        tx_load, tx_busy;
  logic [4:0]  tx_opcode;
  logic [2:0]  tx_srcid, tx_dstid;
  logic [7:0]  tx_msginfo, tx_msgcode, tx_msgsubcode;
  logic        tx_cr;
  logic [11:0] tx_addr;
  logic [7:0]  tx_be;
  logic [4:0]  tx_tag;
  logic        tx_ep;
  logic [63:0] tx_data_in;
  logic        tx_has_data;
  logic [NC-1:0] sb_wire;
  logic        sb_wire_valid;
  logic        corrupt_en = 1'b0;

  // Testbench override mux: flips the received bit for one UI. iverilog's
  // force/release on an instance port is unreliable, so the injection goes
  // through an explicit mux instead.
  wire [NC-1:0] sb_wire_rx = corrupt_en ? ~sb_wire : sb_wire;
  logic        rx_pkt_vld;
  logic [4:0]  rx_opcode;
  logic [2:0]  rx_srcid, rx_dstid;
  logic [7:0]  rx_msginfo, rx_msgcode, rx_msgsubcode;
  logic        rx_cr;
  logic [7:0]  rx_be;
  logic [4:0]  rx_tag;
  logic        rx_ep;
  logic [11:0] rx_addr;
  logic [63:0] rx_data;
  logic        rx_cp_err, rx_dp_err;
  int          errors;

  // rx_pkt_vld is a single-cycle pulse, so the received fields are snapshotted
  // while it is high and compared afterwards.
  logic        sn_vld;
  logic [4:0]  sn_opcode;
  logic [2:0]  sn_srcid, sn_dstid;
  logic [7:0]  sn_msginfo, sn_msgcode, sn_msgsubcode;
  logic        sn_cr;
  logic [7:0]  sn_be;
  logic [4:0]  sn_tag;
  logic        sn_ep;
  logic [11:0] sn_addr;
  logic [63:0] sn_data;
  logic        sn_cp_err, sn_dp_err;

  // --------------------------------------------------------------------------
  // DUT Instance: u_tx – Transmitting sideband codec
  // --------------------------------------------------------------------------
  // This sb_codec instance is wired for transmit-only operation.  The
  // testbench drives the parallel message interface (tx_opcode, tx_srcid,
  // tx_data_in, etc.) and asserts tx_load to begin serialisation.
  //
  // The serial output pair (sb_tx_data / sb_tx_valid) is routed to the
  // corruption mux and then into u_rx.  The receive-side ports
  // (sb_rx_data, sb_rx_valid) are tied low because u_tx is never used
  // as a receiver in this testbench.
  //
  //   Spec ref: Section 6.1.2 – Packet Formats
  //             (u_tx serialises the header/data according to this format)
  // --------------------------------------------------------------------------
  sb_codec u_tx (
    .sbclk(sbclk), .sbreset_n(sbreset_n),
    .tx_load(tx_load), .tx_opcode(tx_opcode),
    .tx_srcid(tx_srcid), .tx_dstid(tx_dstid),
    .tx_msginfo(tx_msginfo), .tx_msgcode(tx_msgcode),
    .tx_msgsubcode(tx_msgsubcode), .tx_cr(tx_cr),
    .tx_addr(tx_addr), .tx_be(tx_be), .tx_tag(tx_tag), .tx_ep(tx_ep),
    .tx_data_in(tx_data_in), .tx_has_data(tx_has_data),
    .tx_busy(tx_busy),
    .sb_tx_data(sb_wire), .sb_tx_valid(sb_wire_valid),
    .sb_rx_data({NC{1'b0}}), .sb_rx_valid(1'b0),
    .rx_pkt_vld(), .rx_opcode(), .rx_srcid(), .rx_dstid(),
    .rx_msginfo(), .rx_msgcode(), .rx_msgsubcode(), .rx_cr(),
    .rx_be(), .rx_tag(), .rx_ep(),
    .rx_addr(), .rx_data(), .rx_cp_err(), .rx_dp_err()
  );

  // --------------------------------------------------------------------------
  // DUT Instance: u_rx – Receiving sideband codec
  // --------------------------------------------------------------------------
  // This sb_codec instance is wired for receive-only operation.  Its
  // sb_rx_data input comes from the corruption mux (sb_wire_rx), which is
  // normally a pass-through of u_tx's serial output.
  //
  // All transmit-side ports are tied to zero / left unconnected because
  // u_rx never originates traffic in this testbench.
  //
  // On reception of a complete sideband message the instance asserts
  // rx_pkt_vld for one sbclk cycle and presents the deserialised fields
  // (rx_opcode, rx_data, rx_cp_err, etc.) which the testbench snapshots
  // and checks.
  //
  //   Spec ref: Section 6.1.2 – Packet Formats
  //             (u_rx deserialises packets per this format)
  //   Spec ref: Section 6.1.3 – Flow Control and Data Integrity
  //             (u_rx computes and reports parity errors via cp_err/dp_err)
  // --------------------------------------------------------------------------
  sb_codec u_rx (
    .sbclk(sbclk), .sbreset_n(sbreset_n),
    .tx_load(1'b0), .tx_opcode(5'b0),
    .tx_srcid(3'b0), .tx_dstid(3'b0),
    .tx_msginfo(8'b0), .tx_msgcode(8'b0),
    .tx_msgsubcode(8'b0), .tx_cr(1'b0),
    .tx_addr(12'b0), .tx_be(8'b0), .tx_tag(5'b0), .tx_ep(1'b0),
    .tx_data_in(64'b0), .tx_has_data(1'b0),
    .tx_busy(),
    .sb_tx_data(), .sb_tx_valid(),
    .sb_rx_data(sb_wire_rx), .sb_rx_valid(sb_wire_valid),
    .rx_pkt_vld(rx_pkt_vld), .rx_opcode(rx_opcode),
    .rx_srcid(rx_srcid), .rx_dstid(rx_dstid),
    .rx_msginfo(rx_msginfo), .rx_msgcode(rx_msgcode),
    .rx_msgsubcode(rx_msgsubcode), .rx_cr(rx_cr),
    .rx_be(rx_be), .rx_tag(rx_tag), .rx_ep(rx_ep),
    .rx_addr(rx_addr), .rx_data(rx_data),
    .rx_cp_err(rx_cp_err), .rx_dp_err(rx_dp_err)
  );

  // --------------------------------------------------------------------------
  // Clock generator – sbclk at 250 MHz (simulation concession)
  // --------------------------------------------------------------------------
  // The `always #2` toggle produces a clock with a 4 ns period (2 ns
  // half-period), corresponding to 250 MHz.
  //
  // IMPORTANT: 250 MHz is a simulation-only reduced rate.  The production
  // sideband signalling rate is 800 MHz per Section 5.13 – Sideband
  // signaling.  The sb_codec is fully synchronous to sbclk and contains
  // no hard-coded cycle-count timing assumptions, so functional behaviour
  // is identical at any frequency.  The lower simulation rate simply
  // reduces event counts and accelerates regression runs.
  //
  //   Spec ref: Section 5.13 – Sideband signaling
  //             (defines 800 MHz as the production sideband clock rate)
  // --------------------------------------------------------------------------
  initial sbclk = 1'b0;
  always #2 sbclk = ~sbclk;     // 250 MHz sideband

  // --------------------------------------------------------------------------
  // Receiver output latch – snapshot on rx_pkt_vld pulse
  // --------------------------------------------------------------------------
  // rx_pkt_vld is a single-cycle pulse generated by u_rx when a complete
  // sideband packet has been deserialised.  Because the codec may
  // overwrite its output registers on the very next clock edge, we must
  // capture every field in the same delta cycle.
  //
  // The #0.1 delay ensures we sample after all blocking assignments in
  // the codec have settled (NBA vs. BA race avoidance).  The snapshot
  // registers (sn_opcode, sn_data, sn_cp_err, etc.) are then compared
  // at leisure by the check_fields task.
  //
  //   Spec ref: Section 6.1.2 – Packet Formats
  //             (defines the fields that are latched here)
  //   Spec ref: Section 6.1.3 – Flow Control and Data Integrity
  //             (cp_err / dp_err flags captured for parity-error checks)
  // --------------------------------------------------------------------------
  always @(posedge rx_pkt_vld) begin
    #0.1;
    sn_vld       = rx_pkt_vld;
    sn_opcode    = rx_opcode;
    sn_srcid     = rx_srcid;
    sn_dstid     = rx_dstid;
    sn_msginfo   = rx_msginfo;
    sn_msgcode   = rx_msgcode;
    sn_msgsubcode= rx_msgsubcode;
    sn_cr        = rx_cr;
    sn_be        = rx_be;
    sn_tag       = rx_tag;
    sn_ep        = rx_ep;
    sn_addr      = rx_addr;
    sn_data      = rx_data;
    sn_cp_err    = rx_cp_err;
    sn_dp_err    = rx_dp_err;
  end

  // Load one packet and wait for the receiver to report it.
  task send_one;
    input [4:0]  op;
    input [2:0]  sid, did;
    input [7:0]  minfo, mcode, msub;
    input        cr;
    input [11:0] addr;
    input [7:0]  be;
    input [4:0]  tag;
    input        ep;
    input [63:0] data;
    input        has_data;
    begin
      @(negedge sbclk);
      tx_opcode    = op;
      tx_srcid     = sid;
      tx_dstid     = did;
      tx_msginfo   = minfo;
      tx_msgcode   = mcode;
      tx_msgsubcode= msub;
      tx_cr        = cr;
      tx_addr      = addr;
      tx_be        = be;
      tx_tag       = tag;
      tx_ep        = ep;
      tx_data_in   = data;
      tx_has_data  = has_data;
      tx_load      = 1'b1;
      @(posedge sbclk);
      @(negedge sbclk);
      tx_load      = 1'b0;
      @(posedge rx_pkt_vld);
      // Hold off until the gap completes so the next load is not dropped.
      wait (!tx_busy);
    end
  endtask

  // Cross-check the snapshotted received fields against what was sent.
  task check_fields;
    input [4:0]  op;
    input [2:0]  sid, did;
    input [7:0]  minfo, mcode, msub;
    input        cr;
    input [11:0] addr;
    input [7:0]  be;
    input [4:0]  tag;
    input        ep;
    input [63:0] data;
    input        has_data;
    begin
      if (!sn_vld) begin
        $display("FAIL ut_sb_codec: no packet received");
        errors = errors + 1;
      end
      if (sn_opcode !== op) begin
        $display("FAIL ut_sb_codec: opcode got %b exp %b", sn_opcode, op);
        errors = errors + 1;
      end
      if (sn_srcid !== sid) begin
        $display("FAIL ut_sb_codec: srcid got %b exp %b", sn_srcid, sid);
        errors = errors + 1;
      end
      if (sn_dstid !== did) begin
        $display("FAIL ut_sb_codec: dstid got %b exp %b", sn_dstid, did);
        errors = errors + 1;
      end
      if (sn_msginfo !== minfo) begin
        $display("FAIL ut_sb_codec: msginfo got %h exp %h", sn_msginfo, minfo);
        errors = errors + 1;
      end
      if (sn_msgcode !== mcode) begin
        $display("FAIL ut_sb_codec: msgcode got %h exp %h", sn_msgcode, mcode);
        errors = errors + 1;
      end
      if (sn_msgsubcode !== msub) begin
        $display("FAIL ut_sb_codec: msgsubcode got %h exp %h",
                 sn_msgsubcode, msub);
        errors = errors + 1;
      end
      if (sn_cr !== cr) begin
        $display("FAIL ut_sb_codec: cr got %b exp %b", sn_cr, cr);
        errors = errors + 1;
      end
      if (sn_addr !== addr) begin
        $display("FAIL ut_sb_codec: addr got %h exp %h", sn_addr, addr);
        errors = errors + 1;
      end
      if (sn_be !== be) begin
        $display("FAIL ut_sb_codec: be got %h exp %h", sn_be, be);
        errors = errors + 1;
      end
      if (sn_tag !== tag) begin
        $display("FAIL ut_sb_codec: tag got %b exp %b", sn_tag, tag);
        errors = errors + 1;
      end
      if (sn_ep !== ep) begin
        $display("FAIL ut_sb_codec: ep got %b exp %b", sn_ep, ep);
        errors = errors + 1;
      end
      if (has_data && sn_data !== data) begin
        $display("FAIL ut_sb_codec: data got %h exp %h", sn_data, data);
        errors = errors + 1;
      end
      if (sn_cp_err !== 1'b0) begin
        $display("FAIL ut_sb_codec: unexpected cp_err");
        errors = errors + 1;
      end
      if (sn_dp_err !== 1'b0) begin
        $display("FAIL ut_sb_codec: unexpected dp_err");
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    errors = 0;
    sbreset_n    = 1'b0;
    tx_load      = 1'b0;
    tx_opcode    = 5'b0;
    tx_srcid     = 3'b0;
    tx_dstid     = 3'b0;
    tx_msginfo   = 8'b0;
    tx_msgcode   = 8'b0;
    tx_msgsubcode= 8'b0;
    tx_cr        = 1'b0;
    tx_addr      = 12'b0;
    tx_be        = 8'b0;
    tx_tag       = 5'b0;
    tx_ep        = 1'b0;
    tx_data_in   = 64'b0;
    tx_has_data  = 1'b0;
    sn_vld       = 1'b0;
    sn_cp_err    = 1'b0;
    sn_dp_err    = 1'b0;
    #5;
    sbreset_n    = 1'b1;
    @(negedge sbclk);

    // 1. Header-only message: LinkMgmt request, no payload.
    send_one(SB_OP_MSG_NODATA, SRCID_ADAPT, SRCID_STACK0,
             8'h00, MC_MBINIT_REQ, 8'h00, 1'b0,
             12'h123, 8'h0F, 5'h1A, 1'b0, 64'b0, 1'b0);
    check_fields(SB_OP_MSG_NODATA, SRCID_ADAPT, SRCID_STACK0,
                 8'h00, MC_MBINIT_REQ, 8'h00, 1'b0,
                 12'h123, 8'h0F, 5'h1A, 1'b0, 64'b0, 1'b0);

    // 2. Message with a 64-bit payload, odd-parity data.
    send_one(SB_OP_MSG_DATA64, SRCID_STACK0, SRCID_ADAPT,
             MS_LM_ACTIVE, MC_LM_RDI_REQ, RDI_REQ_ACTIVE, 1'b1,
             12'hABC, 8'hC3, 5'h07, 1'b1,
             64'hBEEF_DEAD_BEEF_DEAD, 1'b1);
    check_fields(SB_OP_MSG_DATA64, SRCID_STACK0, SRCID_ADAPT,
                 MS_LM_ACTIVE, MC_LM_RDI_REQ, RDI_REQ_ACTIVE, 1'b1,
                 12'hABC, 8'hC3, 5'h07, 1'b1,
                 64'hBEEF_DEAD_BEEF_DEAD, 1'b1);

    // 3. Back-to-back packets: the gap must not bleed into the next header.
    send_one(SB_OP_MSG_NODATA, SRCID_ADAPT, SRCID_STACK0,
             8'h00, MC_MBTRAIN_REQ, 8'h05, 1'b0,
             12'h000, 8'h00, 5'h00, 1'b0, 64'b0, 1'b0);
    check_fields(SB_OP_MSG_NODATA, SRCID_ADAPT, SRCID_STACK0,
                 8'h00, MC_MBTRAIN_REQ, 8'h05, 1'b0,
                 12'h000, 8'h00, 5'h00, 1'b0, 64'b0, 1'b0);
    send_one(SB_OP_MSG_NODATA, SRCID_ADAPT, SRCID_STACK0,
             8'h00, MC_MBTRAIN_RSP, 8'h06, 1'b1,
             12'h7FF, 8'hFF, 5'h1F, 1'b1, 64'b0, 1'b0);
    check_fields(SB_OP_MSG_NODATA, SRCID_ADAPT, SRCID_STACK0,
                 8'h00, MC_MBTRAIN_RSP, 8'h06, 1'b1,
                 12'h7FF, 8'hFF, 5'h1F, 1'b1, 64'b0, 1'b0);

    // 4. CP error injection: hold the serial line high for one header UI,
    // flipping exactly one received bit.
    @(negedge sbclk);
    tx_opcode    = SB_OP_MSG_NODATA;
    tx_srcid     = SRCID_ADAPT;
    tx_dstid     = SRCID_STACK0;
    tx_msginfo   = 8'h00;
    tx_msgcode   = MC_SB_DONE_REQ;
    tx_msgsubcode= 8'h00;
    tx_cr        = 1'b0;
    tx_addr      = 12'h000;
    tx_be        = 8'h00;
    tx_tag       = 5'h00;
    tx_ep        = 1'b0;
    tx_has_data  = 1'b0;
    tx_load      = 1'b1;
    @(posedge sbclk);
    @(negedge sbclk);
    tx_load      = 1'b0;
    // Corrupt UI 10: a header bit, not a parity bit.
    repeat (9) @(posedge sbclk);
    corrupt_en = 1'b1;
    @(posedge sbclk);
    corrupt_en = 1'b0;
    @(posedge rx_pkt_vld);
    #1;
    if (sn_vld !== 1'b1) begin
      $display("FAIL ut_sb_codec: corrupted packet not reported");
      errors = errors + 1;
    end
    if (sn_cp_err !== 1'b1) begin
      $display("FAIL ut_sb_codec: cp_err not flagged on corrupted header");
      errors = errors + 1;
    end

    if (errors == 0) $display("TEST PASSED ut_sb_codec");
    else             $display("FAIL ut_sb_codec: %0d errors", errors);
    $finish;
  end

  initial begin
    #2000000;
    $display("FAIL ut_sb_codec: watchdog timeout");
    $finish;
  end

endmodule
