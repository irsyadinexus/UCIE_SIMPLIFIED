// ============================================================================
// Module    : ut_rdi_sm
// Project   : UCIe 1.0 Simplified Endpoint
// File      : tb/unit/ut_rdi_sm.sv
// ----------------------------------------------------------------------------
//
// SPECIFICATION REFERENCES
//   UCIe 1.0 Specification, Section 8.1 - Raw Die-to-Die Interface (RDI)
//   UCIe 1.0 Specification, Section 8.1.5 - RDI State Status Machine
//   UCIe 1.0 Specification, Section 8.1.6 - RDI bring up flow
//   UCIe 1.0 Specification, Section 8.1.7 - RDI PM flow
//   UCIe 1.0 Specification, Section 8.3.1 - Stall handshake
//   UCIe 1.0 Specification, Section 8.3.2 - State Request and Status
//   UCIe 1.0 Specification, Table 114 - RDI Signal List
//   PLAN.md, Section 15.9 Phase F - Coverage and Verification Integration
// DESCRIPTION
//   Directed unit test for the RDI state machine (rtl/logical_phy/
//   rdi_state_machine.sv). The DUT is instantiated directly and driven
//   pin-by-pin; there is no LTSM and no link, so every state transition is
//   requested explicitly by the stimulus and observed on the status outputs.
//
//   This test exercises the RDI state machine in direct unit-level isolation
//   without an LTSM or partner die. While integrated recovery paths (LinkReset,
//   Disabled, framing-fault LinkError) and PMNAK are also exercised end-to-end
//   in the two-die loopback testbench, this unit test provides exhaustive
//   pin-level verification of all RDI state transitions, unsupported status
//   holds, and the four-phase stall handshake.
//
//   The test walks this sequence:
//
//     RESET --> ACTIVE --> PMNAK(L1) --> ACTIVE --> PMNAK(L2) --> ACTIVE
//           --> hold ACTIVE for RETRAIN --> LINKRESET --> RESET --> ACTIVE
//           --> LINKERROR --> LINKRESET --> RESET --> ACTIVE
//           --> DISABLED --> RESET --> ACTIVE --> four-phase stall
//
//   and, in addition to the state sequence itself, checks the Phase D policy:
//
//     1. ACTIVE waits for the completed LTSM Active Entry result
//        (phy_active_entry_done). A trained link alone must not publish
//        ACTIVE, and local_active_req must drop if the result drops.
//     2. LINKRESET and DISABLED stay published until the LTSM reports RESET
//        through phy_link_reset; an adapter ACTIVE request cannot release
//        them.
//     3. L1 and L2 return PMNAK. The L1 and L2 status encodings are never
//        published.
//     4. RETRAIN is not published: ACTIVE is held, rdi_pl_phyinrecenter stays
//        low, and the DUT has no LTSM-facing output that could change, so the
//        held state is the observable proof that the LTSM is untouched.
//     5. The stall handshake runs all four phases and consumes the adapter
//        acknowledgement rdi_lp_stallack in a registered path.
//
//   The test also keeps the pass-through checks of the original build:
//   pl_cerror, pl_nferror and pl_inband_pres.

// Evidence export (Phase F):
//   On clean zero-error completion, the test exports a minimal JSON evidence
//   fragment to logs/rdi_sm_evidence.json capturing proof of PMNAK power
//   management rejection, LinkReset handling, Disabled handling, and
//   unsupported L1/L2/retrain status publication suppression.
//
// INTERNAL BLOCK DIAGRAM
//
//   +======================================================================+
//   |                            ut_rdi_sm                                 |
//   |                                                                      |
//   |   stimulus (initial)                    scoreboard (task chk)        |
//   |   +------------------------+            +------------------------+   |
//   |   | drives:                |            | compares               |   |
//   |   |  rdi_lp_state_req[3:0] |            |  rdi_pl_state_sts[3:0] |   |
//   |   |  rdi_lp_stallack       |            |  against the expected  |   |
//   |   |  phy_link_trained      |            |  encoding, per step    |   |
//   |   |  phy_active_entry_done |            +-----------+------------+   |
//   |   |  phy_link_reset        |                        |                |
//   |   |  phy_retrain_req       |                        |                |
//   |   |  phy_train_error       |                        |                |
//   |   |  adapter_active_req    |                        |                |
//   |   |  stall_req             |                        |                |
//   |   +-----------+------------+                        |                |
//   |               |                                     |                |
//   |               v                                     ^                |
//   |     +----------------------------------------------+  |              |
//   |     |        rdi_state_machine  (u_dut)            |  |              |
//   |     |  RESET/ACTIVE/PMNAK/LINKRESET/               |--+              |
//   |     |  LINKERROR/DISABLED   spec 8.1.5             |                 |
//   |     |  registered four-phase stall   8.3.1         |                 |
//   |     +----------------------------------------------+                 |
//   |               ^                                                      |
//   |   lclk = 500 MHz (always #1.0), lreset_n driven by stimulus          |
//   +======================================================================+
//
// STIMULUS SEQUENCE
//   The `initial` block asserts a fixed state request on rdi_lp_state_req,
//   waits a bounded number of clocks, then calls `chk` to confirm the DUT
//   reached the corresponding status encoding before moving on. Each step is
//   therefore a request/observe pair, and a wrong or late transition stops
//   the walk at the step that failed. `hold_to` performs the opposite check:
//   the status must still carry the same encoding after a fixed number of
//   clocks, which is how the held LINKRESET, DISABLED and suppressed RETRAIN
//   behaviour is proven.
//
// PASS / FAIL CRITERIA
//   Every `chk` call compares rdi_pl_state_sts against the expected encoding
//   and increments the shared `errors` count on a mismatch. The test prints
//   "TEST PASSED ut_rdi_sm" only when `errors` is zero at the end; the Makefile
//   greps for exactly that string, so a run that skips assertions still fails.
//
// CLOCK / RESET
//   lclk is generated at 500 MHz (2.0 ns period) to match the interface
//   clocking requirement of spec 8.1.2. lreset_n is driven low at the start
//   and released by the stimulus, so the RESET status encoding is observed
//   before any transition is requested.
//
// REVISION HISTORY
//   v0.0.1  2025-XX-XX  Initial creation - RDI state walk and active gating.
//   v0.0.2  2026-09-23  Documentation: expand header, add per-block comments.
//   v0.0.3  2026-09-25  Phase D policy coverage (PLAN.md 15.5): completed
//                       LTSM Active Entry result, PMNAK for L1 and L2, held
//                       LINKRESET and DISABLED until the LTSM RESET result,
//                       suppressed RETRAIN publication, and all four phases
//                       of the registered stall handshake.
//   v0.0.4  2026-09-25  Phase F: add minimal JSON evidence export to
//                       logs/rdi_sm_evidence.json on error-free completion
//                       covering PMNAK, LinkReset, Disabled, and unsupported
//                       L1/L2/retrain exclusions.
//   v0.0.5  2026-09-25  Restore the comment markers on the Table 114 and
//                       PLAN.md references after the Phase F evidence export.
//   v0.0.6  2026-09-25  Restore comment markers on the Phase F evidence
//                       description after the evidence export update.
//   v0.0.7  2026-09-25  Restore the closing initial-block delimiter after the
//                       Phase F evidence writer.
//
// LICENSE
//   SPDX-License-Identifier: Apache-2.0
// ============================================================================
`include "ucie_pkg.sv"
import ucie_pkg::*;

`timescale 1ns/1ps
module ut_rdi_sm;
  logic        lclk, lreset_n;
  logic [3:0]  rdi_lp_state_req;
  logic        adapter_active_req;
  logic        rdi_lp_stallack;
  logic        rdi_lp_linkerror;
  logic [3:0]  rdi_pl_state_sts;
  logic        rdi_pl_inband_pres;
  logic        rdi_pl_linkerror;
  logic        rdi_pl_phyinrecenter;
  logic        rdi_pl_cerror;
  logic        rdi_pl_nferror;
  logic        rdi_pl_trainerror;
  logic        phy_link_trained;
  logic        phy_active_entry_done;
  logic        phy_link_reset;
  logic        phy_retrain_req;
  logic        phy_train_error;
  logic        phy_inband_pres;
  logic        cerror, nferror;
  logic        stall_req, stall_ack;
  logic        stall_complete;
  logic        local_active_req;
  int          errors;

  // -------------------------------------------------------------------------
  // Instantiation: rdi_state_machine (u_dut) - device under test
  //
  // The only instance in this file. Every port is wired either to a stimulus
  // register driven by the `initial` block or to a monitor wire read by `chk`;
  // nothing is tied off, so the test cannot accidentally pass because an input
  // was permanently strapped to a convenient value.
  //
  // The public adapter_active_req input remains connected but is intentionally
  // ignored by Phase D policy. Active entry depends only on the request,
  // physical link, and completed LTSM Active Entry result.
  //
  // The status output under observation is rdi_pl_state_sts, compared against
  // the expected encoding after each request.
  //
  // Spec ref: UCIe 1.0, Section 8.1.5 - RDI State Status Machine; Section 8.1.6
  // - RDI bring up flow; Section 8.3.1 - Stall handshake.
  // -------------------------------------------------------------------------
  rdi_state_machine u_dut (
    .lclk(lclk), .lreset_n(lreset_n),
    .rdi_lp_state_req(rdi_lp_state_req),
    .rdi_lp_linkerror(rdi_lp_linkerror),
    .adapter_active_req(adapter_active_req),
    .rdi_lp_stallack(rdi_lp_stallack),
    .rdi_pl_state_sts(rdi_pl_state_sts),
    .rdi_pl_inband_pres(rdi_pl_inband_pres),
    .rdi_pl_linkerror(rdi_pl_linkerror),
    .rdi_pl_phyinrecenter(rdi_pl_phyinrecenter),
    .rdi_pl_cerror(rdi_pl_cerror),
    .rdi_pl_nferror(rdi_pl_nferror),
    .rdi_pl_trainerror(rdi_pl_trainerror),
    .phy_link_trained(phy_link_trained),
    .phy_active_entry_done(phy_active_entry_done),
    .phy_link_reset(phy_link_reset),
    .phy_retrain_req(phy_retrain_req),
    .phy_train_error(phy_train_error),
    .phy_inband_pres(phy_inband_pres),
    .cerror(cerror), .nferror(nferror),
    .stall_req(stall_req), .stall_ack(stall_ack),
    .stall_complete(stall_complete),
    .local_active_req(local_active_req)
  );

  // -------------------------------------------------------------------------
  // Clock generator: lclk - 500 MHz RDI interface clock
  //
  // Toggles every 1.0 ns, giving a 2.0 ns period and therefore 500 MHz, which
  // is the RDI interface clock rate of this configuration. The RDI is a
  // synchronous interface: state requests are sampled and status is updated on
  // this edge, so the stimulus always changes its inputs away from the edge to
  // avoid a race between the driver and the DUT.
  //
  // Spec ref: UCIe 1.0, Section 8.1.2 - Interface clocking requirements.
  // -------------------------------------------------------------------------
  initial lclk = 1'b0;
  always #1.0 lclk = ~lclk;

  // -------------------------------------------------------------------------
  // task chk: compare the published RDI status against one expectation
  //
  // Records a failure and increments `errors` when rdi_pl_state_sts does not
  // carry the expected encoding. Every state expectation in this file goes
  // through this task, which is what makes "L1, L2 and RETRAIN are never
  // published" a checked statement rather than a comment.
  //
  // Spec ref: UCIe 1.0, Table 114 - RDI Signal List (pl_state_sts encodings).
  // -------------------------------------------------------------------------
  task chk;
    input [64*8-1:0] label;
    input [3:0]     exp;
    begin
      if (rdi_pl_state_sts !== exp) begin
        $display("FAIL ut_rdi_sm: %s: got %01h want %01h", label,
                 rdi_pl_state_sts, exp);
        errors = errors + 1;
      end
    end
  endtask

  // -------------------------------------------------------------------------
  // task step_to: wait for a status encoding, with a bounded deadline
  //
  // Steps until the status matches, then re-checks through `chk` so a timeout
  // produces the same failure message as a wrong encoding.
  // -------------------------------------------------------------------------
  task step_to;
    input [64*8-1:0] label;
    input [3:0]     exp;
    begin
      fork
        begin
          wait (rdi_pl_state_sts == exp);
          #0.1;
        end
        begin
          repeat (2000) @(posedge lclk);
        end
      join_any
      chk(label, exp);
    end
  endtask

  // -------------------------------------------------------------------------
  // task hold_to: prove a status encoding survives a fixed number of clocks
  //
  // Used for the Phase D hold rules: LINKRESET and DISABLED must survive an
  // adapter ACTIVE request, and the suppressed RETRAIN request must leave
  // ACTIVE published.
  // -------------------------------------------------------------------------
  task hold_to;
    input [64*8-1:0] label;
    input [3:0]     exp;
    input int       cycles;
    begin
      repeat (cycles) @(posedge lclk);
      #0.1;
      chk(label, exp);
    end
  endtask

  initial begin
    errors = 0;
    lreset_n        = 1'b0;
    rdi_lp_state_req= RDI_REQ_NOP;
    adapter_active_req = 1'b0;
    rdi_lp_stallack = 1'b0;
    phy_link_trained= 1'b0;
    phy_active_entry_done = 1'b0;
    phy_link_reset  = 1'b0;
    phy_retrain_req = 1'b0;
    phy_train_error = 1'b0;
    phy_inband_pres = 1'b0;
    cerror          = 1'b0;
    nferror         = 1'b0;
    stall_req       = 1'b0;
    rdi_lp_linkerror= 1'b0;

    #5 lreset_n = 1'b1;
    @(negedge lclk);
    chk("reset", RDI_STS_RESET);
    if (stall_ack !== 1'b0) begin
      $display("FAIL ut_rdi_sm: stall_ack high after reset");
      errors = errors + 1;
    end

    // =======================================================================
    // Active Entry gate (spec 8.1.6, PLAN.md Phase D)
    // =======================================================================
    // A trained link is not sufficient. The machine must wait for the private
    // LTSM Active Entry result before it publishes ACTIVE.
    rdi_lp_state_req      = RDI_REQ_ACTIVE;
    phy_link_trained      = 1'b1;
    phy_active_entry_done = 1'b0;
    repeat (4) @(posedge lclk);
    #0.1;
    chk("trained without Active Entry stays RESET", RDI_STS_RESET);

    phy_active_entry_done = 1'b1;
    step_to("active", RDI_STS_ACTIVE);

    // The LTSM owns the remote PHY Active exchange. The RDI local result is
    // valid as soon as its state and the completed Active Entry agree.
    if (!local_active_req) begin
      $display("FAIL ut_rdi_sm: local_active_req low after Active Entry");
      errors = errors + 1;
    end

    // The completed Active Entry result must also gate the local declaration.
    phy_active_entry_done = 1'b0;
    @(posedge lclk); #0.1;
    if (local_active_req) begin
      $display("FAIL ut_rdi_sm: local_active_req high without Active Entry result");
      errors = errors + 1;
    end
    phy_active_entry_done = 1'b1;
    @(posedge lclk); #0.1;

    // =======================================================================
    // L1 and L2 return PMNAK (no L1/L2 status, no LTSM change)
    // =======================================================================
    rdi_lp_state_req = RDI_REQ_L1;
    step_to("pmnak-l1", RDI_STS_PMNAK);
    hold_to("pmnak-l1 holds", RDI_STS_PMNAK, 4);
    rdi_lp_state_req = RDI_REQ_ACTIVE;
    step_to("active2", RDI_STS_ACTIVE);

    rdi_lp_state_req = RDI_REQ_L2;
    step_to("pmnak-l2", RDI_STS_PMNAK);
    hold_to("pmnak-l2 holds", RDI_STS_PMNAK, 4);
    rdi_lp_state_req = RDI_REQ_ACTIVE;
    step_to("active3", RDI_STS_ACTIVE);

    // =======================================================================
    // RETRAIN is suppressed (PLAN.md Phase D)
    // =======================================================================
    // The fixed profile has no Retrain support: the RDI holds ACTIVE, never
    // publishes RETRAIN, and never asserts the recentering indication. The DUT
    // has no LTSM-facing output, so the held state is the observable proof
    // that the LTSM request path is untouched.
    rdi_lp_state_req = RDI_REQ_RETRAIN;
    phy_retrain_req  = 1'b1;
    hold_to("retrain suppressed", RDI_STS_ACTIVE, 6);
    if (rdi_pl_phyinrecenter) begin
      $display("FAIL ut_rdi_sm: phyinrecenter asserted by Retrain request");
      errors = errors + 1;
    end
    phy_retrain_req  = 1'b0;
    rdi_lp_state_req = RDI_REQ_ACTIVE;
    @(posedge lclk); #0.1;
    chk("still active after retrain", RDI_STS_ACTIVE);

    // =======================================================================
    // LINKRESET holds until the LTSM RESET result (PLAN.md Phase D)
    // =======================================================================
    rdi_lp_state_req = RDI_REQ_LINKRESET;
    hold_to("linkreset blocked before stall", RDI_STS_ACTIVE, 4);
    stall_req = 1'b1;
    @(posedge lclk); #0.1;
    rdi_lp_stallack = 1'b1;
    @(posedge lclk); #0.1;
    stall_req = 1'b0;
    @(posedge lclk); #0.1;
    rdi_lp_stallack = 1'b0;
    step_to("linkreset", RDI_STS_LINKRESET);
    // An adapter ACTIVE request alone may not release LinkReset.
    rdi_lp_state_req = RDI_REQ_ACTIVE;
    hold_to("linkreset held", RDI_STS_LINKRESET, 6);

    // LTSM RESET report: the link indications drop and phy_link_reset asserts.
    phy_link_trained      = 1'b0;
    phy_active_entry_done = 1'b0;
    phy_link_reset        = 1'b1;
    @(posedge lclk); #0.1;
    chk("linkreset to reset", RDI_STS_RESET);
    phy_link_reset = 1'b0;
    hold_to("holding active in reset stays in reset", RDI_STS_RESET, 4);
    rdi_lp_state_req = RDI_REQ_NOP;
    @(posedge lclk); #0.1;
    rdi_lp_state_req = RDI_REQ_ACTIVE;
    phy_link_trained      = 1'b1;
    phy_active_entry_done = 1'b1;
    step_to("active4", RDI_STS_ACTIVE);
    // =======================================================================
    // TRAINERROR preempts every state; LinkError recovers only via LinkReset
    // =======================================================================
    phy_train_error = 1'b1;
    @(posedge lclk); #0.1;
    chk("linkerror", RDI_STS_LINKERROR);
    if (!rdi_pl_trainerror) begin
      $display("FAIL ut_rdi_sm: trainerror not reported");
      errors = errors + 1;
    end
    if (!rdi_pl_linkerror) begin
      $display("FAIL ut_rdi_sm: linkerror not reported");
      errors = errors + 1;
    end
    // An ACTIVE request may not clear LinkError.
    rdi_lp_state_req = RDI_REQ_ACTIVE;
    hold_to("linkerror holds", RDI_STS_LINKERROR, 4);

    phy_train_error  = 1'b0;
    rdi_lp_state_req = RDI_REQ_LINKRESET;
    step_to("recover", RDI_STS_LINKRESET);
    phy_link_trained      = 1'b0;
    phy_active_entry_done = 1'b0;
    phy_link_reset        = 1'b1;
    @(posedge lclk); #0.1;
    chk("recover reset", RDI_STS_RESET);
    phy_link_reset = 1'b0;
    rdi_lp_state_req = RDI_REQ_NOP;
    @(posedge lclk); #0.1;
    rdi_lp_state_req = RDI_REQ_ACTIVE;
    phy_link_trained      = 1'b1;
    phy_active_entry_done = 1'b1;
    step_to("active5", RDI_STS_ACTIVE);

    // =======================================================================
    // DISABLED holds until the LTSM RESET result (PLAN.md Phase D)
    // =======================================================================
    rdi_lp_state_req = RDI_REQ_DISABLED;
    hold_to("disabled blocked before stall", RDI_STS_ACTIVE, 4);
    stall_req = 1'b1;
    @(posedge lclk); #0.1;
    rdi_lp_stallack = 1'b1;
    @(posedge lclk); #0.1;
    stall_req = 1'b0;
    @(posedge lclk); #0.1;
    rdi_lp_stallack = 1'b0;
    step_to("disabled", RDI_STS_DISABLED);
    rdi_lp_state_req = RDI_REQ_ACTIVE;
    hold_to("disabled held", RDI_STS_DISABLED, 6);

    phy_link_trained      = 1'b0;
    phy_active_entry_done = 1'b0;
    phy_link_reset        = 1'b1;
    @(posedge lclk); #0.1;
    chk("disabled to reset", RDI_STS_RESET);
    phy_link_reset = 1'b0;
    rdi_lp_state_req = RDI_REQ_NOP;
    @(posedge lclk); #0.1;
    rdi_lp_state_req = RDI_REQ_ACTIVE;
    phy_link_trained      = 1'b1;
    phy_active_entry_done = 1'b1;
    step_to("active6", RDI_STS_ACTIVE);

    // =======================================================================
    // Registered four-phase stall handshake (spec 8.3.1, PLAN.md Phase D)
    // =======================================================================
    // Phase 1: the local request is asserted, the adapter has not yet
    // acknowledged, so stall_ack must stay low. This proves the path is
    // registered and that rdi_lp_stallack is consumed.
    stall_req = 1'b1;
    @(posedge lclk); #0.1;
    if (stall_ack) begin
      $display("FAIL ut_rdi_sm: stall_ack high before lp_stallack");
      errors = errors + 1;
    end

    // Phase 2: the adapter acknowledges; stall_ack registers high one cycle
    // later and the data path must stay quiesced.
    rdi_lp_stallack = 1'b1;
    @(posedge lclk); #0.1;
    if (!stall_ack) begin
      $display("FAIL ut_rdi_sm: stall_ack did not register lp_stallack");
      errors = errors + 1;
    end

    // Phase 3: the requester releases the stall; the window stays open until
    // the adapter drops its acknowledgement.
    stall_req = 1'b0;
    @(posedge lclk); #0.1;
    if (!stall_ack) begin
      $display("FAIL ut_rdi_sm: stall window closed before lp_stallack fell");
      errors = errors + 1;
    end

    // Phase 4: the acknowledgement falls and the handshake completes.
    rdi_lp_stallack = 1'b0;
    @(posedge lclk); #0.1;
    if (stall_ack) begin
      $display("FAIL ut_rdi_sm: stall_ack stuck high after phase 4");
      errors = errors + 1;
    end

    // A request that disappears before the acknowledgement aborts cleanly.
    stall_req = 1'b1;
    @(posedge lclk); #0.1;
    stall_req = 1'b0;
    @(posedge lclk); #0.1;
    if (stall_ack) begin
      $display("FAIL ut_rdi_sm: aborted stall opened the window");
      errors = errors + 1;
    end

    // Error flags forward to the RDI outputs.
    cerror = 1'b1; nferror = 1'b1;
    @(posedge lclk); #0.1;
    if (!rdi_pl_cerror || !rdi_pl_nferror) begin
      $display("FAIL ut_rdi_sm: error flags not forwarded");
      errors = errors + 1;
    end
    cerror = 1'b0; nferror = 1'b0;

    // In-band presence passes through.
    phy_inband_pres = 1'b1;
    @(posedge lclk); #0.1;
    if (!rdi_pl_inband_pres) begin
      $display("FAIL ut_rdi_sm: inband_pres not forwarded");
      errors = errors + 1;
    end
    // =======================================================================
    // P0-2: Adapter LinkError (rdi_lp_linkerror) priority to LINKERROR
    // =======================================================================
    rdi_lp_linkerror = 1'b1;
    step_to("adapter fatal enters linkerror", RDI_STS_LINKERROR);
    rdi_lp_linkerror = 1'b0;
    hold_to("adapter linkerror holds without linkreset", RDI_STS_LINKERROR, 4);
    rdi_lp_state_req = RDI_REQ_LINKRESET;
    step_to("adapter linkerror recovers to linkreset", RDI_STS_LINKRESET);
    phy_link_trained      = 1'b0;
    phy_active_entry_done = 1'b0;
    phy_link_reset        = 1'b1;
    @(posedge lclk); #0.1;
    chk("fatal recovery to reset", RDI_STS_RESET);
    phy_link_reset = 1'b0;
    rdi_lp_state_req = RDI_REQ_NOP;
    @(posedge lclk); #0.1;

    // =======================================================================
    // P0-4: Direct transition from RESET to LINKRESET after sampled NOP
    // =======================================================================
    rdi_lp_state_req = RDI_REQ_LINKRESET;
    step_to("reset to linkreset", RDI_STS_LINKRESET);
    phy_link_reset = 1'b1;
    @(posedge lclk); #0.1;
    chk("return to reset from linkreset", RDI_STS_RESET);
    phy_link_reset = 1'b0;
    rdi_lp_state_req = RDI_REQ_NOP;
    @(posedge lclk); #0.1;
    rdi_lp_state_req = RDI_REQ_ACTIVE;
    phy_link_trained      = 1'b1;
    phy_active_entry_done = 1'b1;
    step_to("active final", RDI_STS_ACTIVE);

    // Phase F: export unit evidence JSON upon clean zero-error completion.
    // Spec ref: UCIe 1.0 Section 8.1.5, Section 8.1.7, Table 114, and
    // PLAN.md Section 15.9 Phase F.
    if (errors == 0) begin
      integer fd;
      fd = $fopen("logs/rdi_sm_evidence.json", "w");
      if (fd != 0) begin
        $fwrite(fd, "{\n");
        $fwrite(fd, "  \"pmnak\": 1,\n");
        $fwrite(fd, "  \"linkreset\": 1,\n");
        $fwrite(fd, "  \"disabled\": 1,\n");
        $fwrite(fd, "  \"unsupported_pm_retrain_reject\": 1,\n");
        $fwrite(fd, "  \"rdi_pmnak\": 1,\n");
        $fwrite(fd, "  \"rdi_linkreset\": 1,\n");
        $fwrite(fd, "  \"rdi_disabled\": 1,\n");
        $fwrite(fd, "  \"rdi_unsupported_pm_retrain_reject\": 1\n");
        $fwrite(fd, "}\n");
        $fclose(fd);
      end
    end

    if (errors == 0) $display("TEST PASSED ut_rdi_sm");
    else             $display("FAIL ut_rdi_sm: %0d errors", errors);
    $finish;
  end

  initial begin
    #100000;
    $display("FAIL ut_rdi_sm: watchdog, state %01h", rdi_pl_state_sts);
    $finish;
  end

endmodule
