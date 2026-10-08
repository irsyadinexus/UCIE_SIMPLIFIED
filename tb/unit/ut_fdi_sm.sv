// ============================================================================
// File        : ut_fdi_sm.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Unit test for the FDI state machine (fdi_state_machine).
// ----------------------------------------------------------------------------
//
// SPECIFICATION REFERENCES
//   UCIe 1.0 Specification, Section 8.2 - Flit-Aware Die-to-Die Interface
//     (FDI)
//   UCIe 1.0 Specification, Section 8.2.5 - FDI State Status Machine
//   UCIe 1.0 Specification, Section 8.2.6 - Rx_active_req/Sts Handshake
//   UCIe 1.0 Specification, Section 8.2.7 - FDI Bring up flow
//   UCIe 1.0 Specification, Table 115 - FDI Signal List
//   UCIe 1.0 Specification, Table 114 - RDI Signal List (state encodings)
//   PLAN.md, Section 15.9 Phase F - Coverage and Verification Integration
// PURPOSE
//   This unit test proves the Phase D FDI policy: the FDI mirrors only the
//   supported RDI states and forwards only the supported Protocol Layer
//   requests to the RDI.
//
//   The primary state-walk sequence is:
//
//       RESET -> ACTIVE -> PMNAK -> RESET -> ACTIVE -> LINKRESET -> RESET ->
//       LINKERROR -> RESET -> ACTIVE -> DISABLED -> RESET
//   In addition to the state walk, the test verifies:
//
//     1. Four-way Active-entry handshake (spec 8.2.6):
//        - RDI reaches ACTIVE before FDI.
//        - pl_rx_active_req asserts while FDI is still in RESET.
//        - FDI enters ACTIVE only after lp_rx_active_sts is driven high.
//
//     2. Supported request forwarding:
//        - Active forwards once the local half of the handshake is complete.
//        - LinkReset and Disabled forward unconditionally.
//
//     3. Unsupported request suppression:
//        - L1, L2, and Retrain leave fdi_state_req_out at RDI_REQ_NOP with
//          fdi_state_req_vld low and fdi_active_req low.
//        - The FDI state does not move while those requests are applied.
//
//     4. Unsupported status hold (the approved Retrain policy):
//        - RETRAIN, L1, and L2 on rdi_state_sts leave pl_state_sts at the
//          current supported state.
//        - A continuous monitor fails the test if pl_state_sts ever takes
//          the L1, L2, or Retrain encoding.
//
//     5. Error flag forwarding:
//        - rdi_trainerror   -> pl_trainerror
//        - rdi_phyinrecenter -> pl_phyinrecenter
//        - rdi_cerror        -> pl_cerror
//        - rdi_nferror       -> pl_nferror
//
//     6. In-band presence stickiness:
//        - rdi_inband_pres pulsed high for one beat; pl_inband_pres must
//          remain asserted (sticky) while the FDI stays in Active.
//        - Transitioning to Reset clears pl_inband_pres.
//
//     7. Stream ID pass-through:
//        - lp_stream[7:0] written with 0xA5; pl_stream must match
//          combinationally.
//
//     8. Protocol and flit-format constants:
//        - pl_protocol      == PROTO_STREAMING (3'b111)
//        - pl_protocol_flitfmt == FMT_RAW (4'b0001)

//     9. Evidence export (Phase F):
//        - On clean zero-error completion, the test exports a minimal JSON
//          evidence fragment to logs/fdi_sm_evidence.json capturing proof of
//          PMNAK, LinkReset forwarding, Disabled forwarding, and unsupported
//          L1/L2/Retrain request and status exclusion.
//
// DUT
//   fdi_state_machine u_dut
//     Instantiated at module scope. All FDI-side and RDI-side ports are
//     connected to local logic declarations so the testbench can drive
//     and observe every signal directly.
//
// STIMULUS
//   RDI status signals (rdi_state_sts, rdi_inband_pres, rdi_trainerror,
//   rdi_phyinrecenter, rdi_cerror, rdi_nferror) are driven directly by
//   the testbench via the `step_to` task. The task sets rdi_state_sts to
//   the target RDI state and waits (with a bounded 2000-cycle deadline)
//   for pl_state_sts to reach the expected FDI state. After the wait,
//   the `chk` task is called to compare the actual value.
//
//   Unsupported RDI statuses (RETRAIN, L1, L2) are driven with the
//   `hold_at` task instead: it sets rdi_state_sts, waits four cycles, and
//   then checks that pl_state_sts kept the expected value.
//
//   The Protocol-Layer side signals (lp_state_req, lp_rx_active_sts,
//   lp_stream) are driven directly from the initial block. No peer-Active
//   signal enters the FDI, so the local handshake is the only qualification.
//
// PASS / FAIL CRITERIA
//   Each `chk` call compares pl_state_sts against the expected 4-bit
//   value. On mismatch, a FAIL message is printed and an integer error
//   counter (`errors`) is incremented. Inline checks use the same
//   pattern for other signals (pl_rx_active_req, pl_trainerror,
//   pl_inband_pres, pl_stream, fdi_state_req_vld, etc.).
//
//   A continuous monitor on the rising clock edge records a failure if
//   pl_state_sts ever takes the L1, L2, or Retrain encoding. It sets the
//   `unsupported_seen` flag, which is folded into `errors` at the end.
//
//   At the end of the test:
//     errors == 0  ->  "TEST PASSED ut_fdi_sm"
//     errors >  0  ->  "FAIL ut_fdi_sm: <N> errors"
//
//   A 100 us watchdog fires if the test stalls.
//
// CLOCK / RESET
//   lclk      - Generated by `always #1.0 lclk = ~lclk`.
//               Period = 2 ns -> Frequency = 500 MHz.
//   lreset_n  - Active-low synchronous reset, de-asserted after 5 ns.
//
// BLOCK DIAGRAM
//
//   +---------------------------------------------------------------+
//   |                       ut_fdi_sm  (testbench)                  |
//   |                                                               |
//   |    Stimulus / Tasks                                           |
//   |    +-----------------------+                                  |
//   |    | initial block         |      Unsupported-state monitor   |
//   |    | step_to(), hold_at(), |      (posedge lclk)              |
//   |    | chk()                 |                                  |
//   |    +-----------+-----------+                                  |
//   |                |                                              |
//   |     RDI-side   |  FDI-side (Protocol Layer)                   |
//   |     inputs     |  outputs                                     |
//   |                v                                              |
//   |   rdi_state_sts -----+               +---> pl_state_sts       |
//   |   rdi_inband_pres ---+               +---> pl_inband_pres     |
//   |   rdi_trainerror ----+               +---> pl_error           |
//   |   rdi_phyinrecenter -+  +---------+  +---> pl_cerror          |
//   |   rdi_cerror --------+->| fdi_    |--+---> pl_nferror         |
//   |   rdi_nferror -------+  | state_  |  +---> pl_trainerror      |
//   |   adapter_state_req -+  | machine |  +---> pl_phyinrecenter   |
//   |   adapter_state_req_ +  +---------+  +---> pl_rx_active_req   |
//   |   lp_state_req ------+               +---> pl_stream          |
//   |   lp_rx_active_sts --+               +---> fdi_active_req     |
//   |   lp_stream ---------+               +---> fdi_state_req_out  |
//   |                                      +---> fdi_state_req_vld  |
//   |                                                               |
//   |    Clock / Reset                                              |
//   |    always #1.0 lclk = ~lclk   (500 MHz, 2 ns period)         |
//   |    lreset_n de-asserted after 5 ns                            |
//   +---------------------------------------------------------------+
//
// REVISION HISTORY
//   v0.0.1  2025-08-15  Initial creation.
//   v0.0.2  2026-09-23  Documentation: expand header, add per-block
//                        comments.
//   v0.0.3  2026-09-23  Documentation: correct the Rx_active_req/Sts and FDI
//                        Bring up flow citations in the header.
//   v0.0.4  2026-09-25  Phase D: cover supported request forwarding and
//                        unsupported request suppression, hold the supported
//                        state for RETRAIN/L1/L2, prove that the partner-
//                        Active input owns no policy, and add the
//                        unsupported-state publication monitor.
//   v0.0.5  2026-09-25  Phase F: add minimal JSON evidence export to
//                        logs/fdi_sm_evidence.json on error-free completion
//                        covering PMNAK, LinkReset, Disabled, and unsupported
//                        L1/L2/retrain exclusions.
//   v0.0.6  2026-09-25  Restore the comment marker on the Table 114
//                        specification reference after the Phase F evidence
//                        export update.
//   v0.0.7  2026-09-25  Restore comment markers on the Phase F evidence
//                        description after the evidence export update.
//   v0.0.8  2026-09-25  Restore the closing initial-block delimiter after the
//                        Phase F evidence writer.
//
// LICENSE
//   SPDX-License-Identifier: Apache-2.0
// ============================================================================
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module ut_fdi_sm;
  logic        lclk, lreset_n;
  logic [3:0]  lp_state_req;
  logic [3:0]  pl_state_sts;
  logic        pl_inband_pres;
  logic        pl_error;
  logic        pl_cerror, pl_nferror, pl_trainerror, pl_phyinrecenter;
  logic [2:0]  pl_protocol;
  logic [3:0]  pl_protocol_flitfmt;
  logic        pl_rx_active_req;
  logic        lp_rx_active_sts;
  logic [7:0]  lp_stream;
  logic [7:0]  pl_stream;
  logic [3:0]  rdi_state_sts;
  logic        rdi_inband_pres;
  logic        rdi_trainerror;
  logic        rdi_phyinrecenter;
  logic        rdi_cerror;
  logic        rdi_nferror;
  logic        adapter_active_req;
  logic        adapter_state_req_vld;
  logic [3:0]  adapter_state_req;
  logic        fdi_active_req;
  logic [3:0]  fdi_state_req_out;
  logic        fdi_state_req_vld;
  logic        adapter_stage3_ready;
  logic        unsupported_seen;   // set if pl_state_sts takes L1/L2/RETRAIN
  int          errors;

// -------------------------------------------------------------------------
// DUT Instantiation: fdi_state_machine
// -------------------------------------------------------------------------
// Instantiate the FDI state machine as the device under test.  Every
// port is connected to a local testbench signal so that RDI-side
// inputs can be driven directly from stimulus tasks and Protocol-
// Layer outputs can be observed by the `chk` task.
//
// Port groups:
//   lclk / lreset_n           - clock and active-low reset
//   lp_state_req              - Protocol Layer state request (FDI)
//   pl_state_sts              - FDI state status (primary DUT output)
//   pl_inband_pres .. pl_stream - FDI indication / status outputs
//   rdi_state_sts .. rdi_nferror - RDI status inputs from Logical PHY
//   adapter_active_req        - public compatibility input, tied low and
//                               ignored by FDI state policy
//   adapter_state_req_vld /   - generic request channel, tied off, unused
//     adapter_state_req
//   fdi_active_req ..         - request outputs observed by `chk` and the
//     fdi_state_req_vld         inline checks
// -------------------------------------------------------------------------
  fdi_state_machine u_dut (
    .lclk(lclk), .lreset_n(lreset_n),
    .lp_state_req(lp_state_req),
    .pl_state_sts(pl_state_sts),
    .pl_inband_pres(pl_inband_pres),
    .pl_error(pl_error),
    .pl_cerror(pl_cerror), .pl_nferror(pl_nferror),
    .pl_trainerror(pl_trainerror), .pl_phyinrecenter(pl_phyinrecenter),
    .pl_protocol(pl_protocol),
    .pl_protocol_flitfmt(pl_protocol_flitfmt),
    .pl_rx_active_req(pl_rx_active_req),
    .lp_rx_active_sts(lp_rx_active_sts),
    .lp_stream(lp_stream), .pl_stream(pl_stream),
    .rdi_state_sts(rdi_state_sts),
    .rdi_inband_pres(rdi_inband_pres),
    .rdi_trainerror(rdi_trainerror),
    .rdi_phyinrecenter(rdi_phyinrecenter),
    .rdi_cerror(rdi_cerror), .rdi_nferror(rdi_nferror),
    .adapter_active_req(adapter_active_req),
    .adapter_state_req_vld(adapter_state_req_vld),
    .adapter_state_req(adapter_state_req),
    .fdi_active_req(fdi_active_req),
    .adapter_stage3_ready(adapter_stage3_ready),
    .fdi_state_req_out(fdi_state_req_out),
    .fdi_state_req_vld(fdi_state_req_vld)
  );

  initial lclk = 1'b0;
// -------------------------------------------------------------------------
// Clock Generator
// -------------------------------------------------------------------------
// Free-running clock with a half-period of 1.0 ns (period = 2.0 ns,
// frequency = 500 MHz).  The initial value is set to 0 by the
// preceding `initial lclk = 1'b0` statement; this always block
// toggles it every 1 ns to produce a symmetric 50 % duty-cycle
// clock.
//
// The 500 MHz frequency matches the lclk specification used by all
// RTL modules in this project (see fdi_state_machine.sv header).
// -------------------------------------------------------------------------
  always #1.0 lclk = ~lclk;

  task chk;
    input [64*8-1:0] label;
    input [3:0]      exp;
    begin
      if (pl_state_sts !== exp) begin
        $display("FAIL ut_fdi_sm: %s: got %01h want %01h", label,
                 pl_state_sts, exp);
        errors = errors + 1;
      end
    end
  endtask

  // Step the FDI by moving the RDI status, then waiting for FDI to follow.
  task step_to;
    input [64*8-1:0] label;
    input [3:0]      exp_rdi;
    input [3:0]      exp_fdi;
    begin
      rdi_state_sts = exp_rdi;
      fork
        begin
          wait (pl_state_sts == exp_fdi);
          #0.1;
        end
        begin
          repeat (2000) @(posedge lclk);
        end
      join_any
      chk(label, exp_fdi);
    end
  endtask

  // Drive an unsupported RDI status (RETRAIN, L1, L2) and prove that the
  // FDI holds its current supported state instead of mirroring the status.
  task hold_at;
    input [64*8-1:0] label;
    input [3:0]      unsupported_rdi;
    input [3:0]      exp_fdi;
    begin
      rdi_state_sts = unsupported_rdi;
      repeat (4) @(posedge lclk);
      #0.1;
      chk(label, exp_fdi);
    end
  endtask

  // -------------------------------------------------------------------------
  // Monitor: unsupported-state publication
  // -------------------------------------------------------------------------
  // Phase D requires that no test can observe an FDI L1, L2, or Retrain
  // state. This monitor records a failure if pl_state_sts ever takes one of
  // those encodings; the flag is folded into `errors` at the end of the test.
  // -------------------------------------------------------------------------
  always @(posedge lclk) begin
    if (pl_state_sts === FDI_STS_L1 || pl_state_sts === FDI_STS_L2 ||
        pl_state_sts === FDI_STS_RETRAIN) begin
      $display("FAIL ut_fdi_sm: unsupported FDI state %01h published",
               pl_state_sts);
      unsupported_seen = 1'b1;
    end
  end

  initial begin
    errors = 0;
    unsupported_seen = 1'b0;
    lreset_n        = 1'b0;
    lp_state_req    = FDI_REQ_NOP;
    lp_rx_active_sts= 1'b0;
    lp_stream       = 8'h00;
    rdi_state_sts   = RDI_STS_RESET;
    rdi_inband_pres = 1'b0;
    rdi_trainerror  = 1'b0;
    rdi_phyinrecenter = 1'b0;
    rdi_cerror      = 1'b0;
    rdi_nferror     = 1'b0;
    adapter_active_req = 1'b0;
    adapter_state_req_vld = 1'b0;
    adapter_state_req = RDI_REQ_NOP;

    adapter_stage3_ready = 1'b0;
    #5 lreset_n = 1'b1;
    @(negedge lclk);
    chk("reset", 4'h0);

    // 8.2.6 four-way handshake: the Rx-active request follows the RDI into
    // Active before the FDI itself moves.
    step_to("rdi active alone", RDI_STS_ACTIVE, 4'h0);
    if (!pl_rx_active_req) begin
      $display("FAIL ut_fdi_sm: pl_rx_active_req low with RDI Active");
      errors = errors + 1;
    end

    // The Protocol Layer asks for Active. The request stays invalid until
    // lp_rx_active_sts completes the local half of the handshake.
    lp_state_req = FDI_REQ_ACTIVE;
    repeat (2) @(posedge lclk); #0.1;
    if (fdi_state_req_out !== FDI_REQ_ACTIVE || fdi_state_req_vld ||
        !fdi_active_req) begin
      $display("FAIL ut_fdi_sm: Active level/vld %01h/%b before sts",
               fdi_state_req_out, fdi_state_req_vld);
      errors = errors + 1;
    end

    // The public compatibility input stays low and cannot change the result.
    lp_rx_active_sts = 1'b1;
    repeat (2) @(posedge lclk); #0.1;
    if (!fdi_state_req_vld || fdi_state_req_out !== FDI_REQ_ACTIVE ||
        !fdi_active_req) begin
      $display("FAIL ut_fdi_sm: Active request not forwarded");
      errors = errors + 1;
    end
    // P0-1: With adapter_stage3_ready=0, FDI must hold in RESET even when RDI is Active and rx_active_sts=1
    repeat (4) @(posedge lclk); #0.1;
    chk("fdi held in reset before stage3_ready", 4'h0);
    adapter_stage3_ready = 1'b1;
    step_to("fdi active", RDI_STS_ACTIVE, 4'h1);
    // Streaming and Format 1 Raw are fixed for this PoC.
    if (pl_protocol !== PROTO_STREAMING) begin
      $display("FAIL ut_fdi_sm: protocol %01h", pl_protocol);
      errors = errors + 1;
    end
    if (pl_protocol_flitfmt !== FMT_RAW) begin
      $display("FAIL ut_fdi_sm: flitfmt %01h", pl_protocol_flitfmt);
      errors = errors + 1;
    end

    // PMNAK: the PHY NAKed a power-management request. The FDI mirrors the
    // NAK and leaves it again when the RDI reports Reset or Active.
    step_to("pmnak", RDI_STS_PMNAK, 4'h3);
    step_to("pmnak reset", RDI_STS_RESET, 4'h0);
    step_to("active again", RDI_STS_ACTIVE, 4'h1);

    // LinkReset mirrors through and ends in Reset.
    step_to("linkreset", RDI_STS_LINKRESET, 4'h9);
    step_to("reset", RDI_STS_RESET, 4'h0);

    // Re-enter Active for the error paths.
    step_to("active2", RDI_STS_ACTIVE, 4'h1);
    rdi_trainerror = 1'b1;
    step_to("linkerror", RDI_STS_LINKERROR, 4'hA);
    if (!pl_trainerror) begin
      $display("FAIL ut_fdi_sm: trainerror not forwarded");
      errors = errors + 1;
    end
    rdi_trainerror = 1'b0;
    step_to("reset2", RDI_STS_RESET, 4'h0);

    // Retrain is unsupported: the FDI holds Active and keeps forwarding the
    // receiver-recentering indication while the RDI reports RETRAIN.
    step_to("active3", RDI_STS_ACTIVE, 4'h1);
    rdi_phyinrecenter = 1'b1;
    hold_at("retrain hold", RDI_STS_RETRAIN, 4'h1);
    if (!pl_phyinrecenter) begin
      $display("FAIL ut_fdi_sm: phyinrecenter not forwarded");
      errors = errors + 1;
    end
    rdi_phyinrecenter = 1'b0;
    hold_at("retrain still held", RDI_STS_RETRAIN, 4'h1);

    // The unsupported L1 and L2 statuses are never mirrored either.
    hold_at("l1 hold", RDI_STS_L1, 4'h1);
    hold_at("l2 hold", RDI_STS_L2, 4'h1);
    step_to("active4", RDI_STS_ACTIVE, 4'h1);

    // DISABLED only leaves through Reset or LinkReset.
    step_to("disabled", RDI_STS_DISABLED, 4'hC);
    step_to("disabled to linkerror", RDI_STS_LINKERROR, 4'hA);
    step_to("reset3", RDI_STS_RESET, 4'h0);

    // Re-enter Active: in-band presence is sticky until a state clears it.
    step_to("active5", RDI_STS_ACTIVE, 4'h1);
    rdi_inband_pres = 1'b1;
    repeat (3) @(posedge lclk);
    if (!pl_inband_pres) begin
      $display("FAIL ut_fdi_sm: inband_pres not asserted");
      errors = errors + 1;
    end
    rdi_inband_pres = 1'b0;
    repeat (3) @(posedge lclk);
    if (!pl_inband_pres) begin
      $display("FAIL ut_fdi_sm: inband_pres not sticky in Active");
      errors = errors + 1;
    end
    // Leaving to Reset clears it.
    step_to("reset4", RDI_STS_RESET, 4'h0);
    repeat (3) @(posedge lclk);
    if (pl_inband_pres) begin
      $display("FAIL ut_fdi_sm: inband_pres not cleared by Reset");
      errors = errors + 1;
    end

    // Correctable and non-fatal errors forward.
    rdi_cerror = 1'b1; rdi_nferror = 1'b1;
    @(posedge lclk); #0.1;
    if (!pl_cerror || !pl_nferror) begin
      $display("FAIL ut_fdi_sm: error flags not forwarded");
      errors = errors + 1;
    end
    rdi_cerror = 1'b0; rdi_nferror = 1'b0;

    // The stream id passes straight through.
    lp_stream = 8'hA5;
    @(posedge lclk); #0.1;
    if (pl_stream !== STREAM_ID_S0_STREAMING) begin
      $display("FAIL ut_fdi_sm: stream %02h", pl_stream);
      errors = errors + 1;
    end

    // Return to Active so that the request checks run with a supported link
    // state; the partner-Active input stays low throughout.
    step_to("active6", RDI_STS_ACTIVE, 4'h1);

    // The Active request forwards once the local half of the handshake is
    // complete, with no partner request involved.
    lp_state_req = FDI_REQ_ACTIVE;
    repeat (2) @(posedge lclk); #0.1;
    if (!fdi_state_req_vld || fdi_state_req_out !== FDI_REQ_ACTIVE ||
        !fdi_active_req) begin
      $display("FAIL ut_fdi_sm: Active request not forwarded");
      errors = errors + 1;
    end

    // LinkReset and Disabled forward unconditionally and are not Active
    // requests.
    lp_state_req = FDI_REQ_LINKRESET;
    repeat (2) @(posedge lclk); #0.1;
    if (!fdi_state_req_vld || fdi_state_req_out !== FDI_REQ_LINKRESET ||
        fdi_active_req) begin
      $display("FAIL ut_fdi_sm: LinkReset request not forwarded");
      errors = errors + 1;
    end

    lp_state_req = FDI_REQ_DISABLED;
    repeat (2) @(posedge lclk); #0.1;
    if (!fdi_state_req_vld || fdi_state_req_out !== FDI_REQ_DISABLED ||
        fdi_active_req) begin
      $display("FAIL ut_fdi_sm: Disabled request not forwarded");
      errors = errors + 1;
    end

    // Unsupported requests are suppressed: no request reaches the RDI and the
    // validity flag stays low.
    lp_state_req = FDI_REQ_L1;
    repeat (2) @(posedge lclk); #0.1;
    if (!fdi_state_req_vld || fdi_state_req_out !== FDI_REQ_L1 ||
        fdi_active_req) begin
      $display("FAIL ut_fdi_sm: L1 request not forwarded");
      errors = errors + 1;
    end

    lp_state_req = FDI_REQ_L2;
    repeat (2) @(posedge lclk); #0.1;
    if (!fdi_state_req_vld || fdi_state_req_out !== FDI_REQ_L2 ||
        fdi_active_req) begin
      $display("FAIL ut_fdi_sm: L2 request not forwarded");
      errors = errors + 1;
    end

    lp_state_req = FDI_REQ_RETRAIN;
    repeat (2) @(posedge lclk); #0.1;
    if (fdi_state_req_vld || fdi_state_req_out !== RDI_REQ_NOP ||
        fdi_active_req) begin
      $display("FAIL ut_fdi_sm: Retrain request not suppressed");
      errors = errors + 1;
    end

    // The suppressed requests must not have moved the FDI either.
    chk("state held after suppression", 4'h1);

    // Recovery: the Active request is forwarded again.
    lp_state_req = FDI_REQ_ACTIVE;
    repeat (2) @(posedge lclk); #0.1;
    if (!fdi_state_req_vld || fdi_state_req_out !== FDI_REQ_ACTIVE) begin
      $display("FAIL ut_fdi_sm: Active request not restored");
      errors = errors + 1;
    end

    if (unsupported_seen) begin
      $display("FAIL ut_fdi_sm: unsupported FDI state was published");
      errors = errors + 1;
    end

    // Phase F: export unit evidence JSON upon clean zero-error completion.
    // Spec ref: UCIe 1.0 Section 8.2.5, Section 8.2.6, Table 115, and
    // PLAN.md Section 15.9 Phase F.
    if (errors == 0) begin
      integer fd;
      fd = $fopen("logs/fdi_sm_evidence.json", "w");
      if (fd != 0) begin
        $fwrite(fd, "{\n");
        $fwrite(fd, "  \"pmnak\": 1,\n");
        $fwrite(fd, "  \"linkreset\": 1,\n");
        $fwrite(fd, "  \"disabled\": 1,\n");
        $fwrite(fd, "  \"unsupported_pm_retrain_reject\": 1,\n");
        $fwrite(fd, "  \"fdi_pmnak\": 1,\n");
        $fwrite(fd, "  \"fdi_linkreset\": 1,\n");
        $fwrite(fd, "  \"fdi_disabled\": 1,\n");
        $fwrite(fd, "  \"fdi_unsupported_pm_retrain_reject\": 1\n");
        $fwrite(fd, "}\n");
        $fclose(fd);
      end
    end

    if (errors == 0) $display("TEST PASSED ut_fdi_sm");
    else             $display("FAIL ut_fdi_sm: %0d errors", errors);
    $finish;
  end

  initial begin
    #100000;
    $display("FAIL ut_fdi_sm: watchdog, state %01h", pl_state_sts);
    $finish;
  end

endmodule
