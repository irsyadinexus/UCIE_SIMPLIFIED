// Unit test: ltsm. A single LTSM is driven through the full training
// sequence. The partner is a second sb_codec plus a responder that echoes
// each received request back as the matching response.
`timescale 1ns/1ps
`include "ucie_pkg.sv"
import ucie_pkg::*;

module ut_ltsm;
  logic        lclk, lreset_n, sbclk, sbreset_n;
  logic        start_link_train, adapter_active_req;
  logic        link_trained, train_error, link_reset_out, phy_retrain_done;
  logic [7:0]  ltsm_state;
  logic        lnk_is_x8;
  logic [1:0]  degrade_lanes;
  logic        sb_msg_timeout, sb_stall_sent;
  logic        pat_enable, pat_lfsr_reset, pat_lfsr_enable, pat_done;
  logic        tmr_start, tmr_run, tmr_expired;
  int          errors;

  // LTSM <-> local codec
  logic        sb_tx_load, sb_tx_busy;
  logic [4:0]  sb_tx_opcode;
  logic [2:0]  sb_tx_srcid, sb_tx_dstid;
  logic [7:0]  sb_tx_msginfo, sb_tx_msgcode, sb_tx_msgsubcode;
  logic [7:0]  sb_tx_be;
  logic [4:0]  sb_tx_tag;
  logic        sb_tx_ep;
  logic [11:0] sb_tx_addr;
  logic [63:0] sb_tx_data_in;
  logic        sb_tx_has_data;
  logic [NC-1:0] loc_sb_data, par_sb_data;
  logic        loc_sb_valid, par_sb_valid;

  // LTSM receive side (fed from the partner codec)
  logic        sb_rx_pkt_vld;
  logic [4:0]  sb_rx_opcode;
  logic [2:0]  sb_rx_srcid, sb_rx_dstid;
  logic [7:0]  sb_rx_msginfo, sb_rx_msgcode, sb_rx_msgsubcode;
  logic        sb_rx_cp_err, sb_rx_dp_err;

  // Partner codec transmit controls
  logic        par_tx_load, par_tx_busy;
  logic [4:0]  par_tx_opcode;
  logic [2:0]  par_tx_srcid, par_tx_dstid;
  logic [7:0]  par_tx_msginfo, par_tx_msgcode, par_tx_msgsubcode;
  logic [7:0]  par_tx_be;
  logic [4:0]  par_tx_tag;
  logic        par_tx_ep;
  logic [11:0] par_tx_addr;
  logic [63:0] par_tx_data_in;
  logic        par_tx_has_data;

  // Partner receive snapshot
  logic        par_rx_pkt_vld;
  logic [4:0]  par_rx_opcode;
  logic [2:0]  par_rx_srcid, par_rx_dstid;
  logic [7:0]  par_rx_msginfo, par_rx_msgcode, par_rx_msgsubcode;
  logic        par_rx_cp_err, par_rx_dp_err;

  ltsm #(.NLANES(NLANES_MAX)) u_dut (
    .lclk(lclk), .lreset_n(lreset_n), .sbclk(sbclk), .sbreset_n(sbreset_n),
    .start_link_train(start_link_train),
    .adapter_active_req(adapter_active_req),
    .link_trained(link_trained), .train_error(train_error),
    .link_reset_out(link_reset_out), .phy_retrain_done(phy_retrain_done),
    .ltsm_state(ltsm_state), .lnk_is_x8(lnk_is_x8),
    .degrade_lanes(degrade_lanes),
    .sb_tx_load(sb_tx_load), .sb_tx_opcode(sb_tx_opcode),
    .sb_tx_srcid(sb_tx_srcid), .sb_tx_dstid(sb_tx_dstid),
    .sb_tx_msginfo(sb_tx_msginfo), .sb_tx_msgcode(sb_tx_msgcode),
    .sb_tx_msgsubcode(sb_tx_msgsubcode), .sb_tx_be(sb_tx_be),
    .sb_tx_tag(sb_tx_tag), .sb_tx_ep(sb_tx_ep), .sb_tx_addr(sb_tx_addr),
    .sb_tx_data_in(sb_tx_data_in), .sb_tx_has_data(sb_tx_has_data),
    .sb_tx_busy(sb_tx_busy),
    .sb_rx_pkt_vld(sb_rx_pkt_vld), .sb_rx_opcode(sb_rx_opcode),
    .sb_rx_srcid(sb_rx_srcid), .sb_rx_dstid(sb_rx_dstid),
    .sb_rx_msginfo(sb_rx_msginfo), .sb_rx_msgcode(sb_rx_msgcode),
    .sb_rx_msgsubcode(sb_rx_msgsubcode),
    .sb_rx_cp_err(sb_rx_cp_err), .sb_rx_dp_err(sb_rx_dp_err),
    .sb_msg_timeout(sb_msg_timeout), .sb_stall_sent(sb_stall_sent),
    .pat_enable(pat_enable), .pat_select(), .pat_lfsr_reset(pat_lfsr_reset),
    .pat_lfsr_enable(pat_lfsr_enable), .pat_done(pat_done),
    .tmr_start(tmr_start), .tmr_run(tmr_run), .tmr_expired(tmr_expired)
  );

  sb_codec u_loc (
    .sbclk(sbclk), .sbreset_n(sbreset_n),
    .tx_load(sb_tx_load), .tx_opcode(sb_tx_opcode),
    .tx_srcid(sb_tx_srcid), .tx_dstid(sb_tx_dstid),
    .tx_msginfo(sb_tx_msginfo), .tx_msgcode(sb_tx_msgcode),
    .tx_msgsubcode(sb_tx_msgsubcode), .tx_be(sb_tx_be), .tx_cr(1'b0),
    .tx_tag(sb_tx_tag), .tx_ep(sb_tx_ep), .tx_addr(sb_tx_addr),
    .tx_data_in(sb_tx_data_in), .tx_has_data(sb_tx_has_data),
    .tx_busy(sb_tx_busy),
    .sb_tx_data(loc_sb_data), .sb_tx_valid(loc_sb_valid),
    .sb_rx_data(par_sb_data), .sb_rx_valid(par_sb_valid),
    .rx_pkt_vld(sb_rx_pkt_vld), .rx_opcode(sb_rx_opcode),
    .rx_srcid(sb_rx_srcid), .rx_dstid(sb_rx_dstid),
    .rx_msginfo(sb_rx_msginfo), .rx_msgcode(sb_rx_msgcode),
    .rx_msgsubcode(sb_rx_msgsubcode), .rx_cr(),
    .rx_be(), .rx_tag(), .rx_ep(), .rx_addr(), .rx_data(),
    .rx_cp_err(sb_rx_cp_err), .rx_dp_err(sb_rx_dp_err)
  );

  sb_codec u_par (
    .sbclk(sbclk), .sbreset_n(sbreset_n),
    .tx_load(par_tx_load), .tx_opcode(par_tx_opcode),
    .tx_srcid(par_tx_srcid), .tx_dstid(par_tx_dstid),
    .tx_msginfo(par_tx_msginfo), .tx_msgcode(par_tx_msgcode),
    .tx_msgsubcode(par_tx_msgsubcode), .tx_be(par_tx_be), .tx_cr(1'b0),
    .tx_tag(par_tx_tag), .tx_ep(par_tx_ep), .tx_addr(par_tx_addr),
    .tx_data_in(par_tx_data_in), .tx_has_data(par_tx_has_data),
    .tx_busy(par_tx_busy),
    .sb_tx_data(par_sb_data), .sb_tx_valid(par_sb_valid),
    .sb_rx_data(loc_sb_data), .sb_rx_valid(loc_sb_valid),
    .rx_pkt_vld(par_rx_pkt_vld), .rx_opcode(par_rx_opcode),
    .rx_srcid(par_rx_srcid), .rx_dstid(par_rx_dstid),
    .rx_msginfo(par_rx_msginfo), .rx_msgcode(par_rx_msgcode),
    .rx_msgsubcode(par_rx_msgsubcode), .rx_cr(),
    .rx_be(), .rx_tag(), .rx_ep(), .rx_addr(), .rx_data(),
    .rx_cp_err(par_rx_cp_err), .rx_dp_err(par_rx_dp_err)
  );

  // Responder: on each received request, send the paired response with the
  // same subcode. The LTSM accepts a request whose subcode matches its own as
  // a response, so a symmetric echo completes the handshake either way.
  always @(posedge sbclk or negedge sbreset_n) begin
    if (!sbreset_n) begin
      par_tx_load  <= 1'b0;
      par_tx_opcode<= 5'b0;
      par_tx_srcid <= 3'b0;
      par_tx_dstid <= 3'b0;
      par_tx_msginfo <= 8'b0;
      par_tx_msgcode <= 8'b0;
      par_tx_msgsubcode <= 8'b0;
      par_tx_be     <= 8'b0;
      par_tx_tag    <= 5'b0;
      par_tx_ep     <= 1'b0;
      par_tx_addr   <= 12'b0;
      par_tx_data_in<= 64'b0;
      par_tx_has_data<= 1'b0;
    end else begin
      par_tx_load  <= 1'b0;
      if (par_rx_pkt_vld && !par_tx_busy && !par_tx_load) begin
        par_tx_load    <= 1'b1;
        par_tx_opcode  <= par_rx_opcode;
        par_tx_srcid   <= par_rx_dstid;
        par_tx_dstid   <= par_rx_srcid;
        par_tx_msginfo <= (par_rx_msgsubcode == MS_REPAIR_INIT)
                          ? MS_LKS_DONE : par_rx_msginfo;
        par_tx_msgcode <= rsp_for(par_rx_msgcode);
        par_tx_msgsubcode <= par_rx_msgsubcode;
        par_tx_be      <= 8'b0;
        par_tx_tag     <= 5'b0;
        par_tx_ep      <= 1'b0;
        par_tx_addr    <= 12'b0;
        par_tx_data_in <= 64'b0;
        par_tx_has_data<= 1'b0;
      end
    end
  end

  // Map a request code to its paired response.
  function automatic logic [7:0] rsp_for(input logic [7:0] code);
    case (code)
      MC_SB_DONE_REQ:  rsp_for = MC_SB_DONE_RSP;
      MC_MBINIT_REQ:   rsp_for = MC_MBINIT_RSP;
      MC_MBTRAIN_REQ:  rsp_for = MC_MBTRAIN_RSP;
      MC_PHYR_REQ:     rsp_for = MC_PHYR_RSP;
      default:         rsp_for = MC_TE_RSP;
    endcase
  endfunction

  // The training pattern completes after LFSR_PATTERN_UI in LINKINIT.
  // A simple counter stands in for the real generator here.
  logic [13:0] pat_ui;
  always @(posedge lclk or negedge lreset_n) begin
    if (!lreset_n || !pat_enable) pat_ui <= '0;
    else                           pat_ui <= pat_ui + 1'b1;
  end
  assign pat_done = pat_enable && pat_lfsr_enable &&
                    (pat_ui == LFSR_PATTERN_UI-1);

  // Timer: DIV keeps the test fast. LIMIT_CYCLES stays at the spec value.
  ucie_timer #(.DIV(64)) u_tmr (
    .clk(lclk), .reset_n(lreset_n), .start(tmr_start),
    .running(tmr_run), .expired(tmr_expired)
  );

  initial lclk  = 1'b0;
  initial sbclk = 1'b0;
  // Single clock domain: the PoC samples the sideband on the same edge as
  // the training logic, so a 1.0 ns load pulse cannot be missed.
  always #0.5 lclk  = ~lclk;
  always #0.5 sbclk = ~sbclk;

  // Record the sequence of states the LTSM walks through.
  ltsm_state_t seen [0:63];
  int          seen_n;

  always @(posedge lclk) begin
    if (lreset_n) begin
      if (seen_n == 0 || ltsm_state !== seen[seen_n-1]) begin
        seen[seen_n] = ltsm_state;
        seen_n = seen_n + 1;
      end
    end
  end

  task expect_state;
    input ltsm_state_t exp;
    begin
      // Wait until the LTSM leaves this state or the deadline passes.
      fork
        begin
          wait (ltsm_state != exp);
          #0.1;
        end
        begin
          repeat (200000) @(posedge lclk);
        end
      join_any
      if (ltsm_state === exp) begin
        $display("FAIL ut_ltsm: stuck in %s", "%02h", exp);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    errors = 0;
    seen_n = 0;
    lreset_n        = 1'b0;
    sbreset_n       = 1'b0;
    start_link_train= 1'b0;
    adapter_active_req = 1'b0;
    #5;
    lreset_n        = 1'b1;
    sbreset_n       = 1'b1;

    // RESET must hold until training is requested.
    @(negedge lclk);
    if (ltsm_state !== LT_RESET) begin
      $display("FAIL ut_ltsm: not in RESET after power-on");
      errors = errors + 1;
    end

    start_link_train = 1'b1;
    adapter_active_req = 1'b1;

    // Walk every sub-state in order. Each call blocks until the LTSM moves on.
    expect_state(LT_RESET);
    expect_state(LT_SBINIT);
    expect_state(LT_MBINIT_PARAM);
    expect_state(LT_MBINIT_CAL);
    expect_state(LT_MBINIT_RPCLK);
    expect_state(LT_MBINIT_RPVAL);
    expect_state(LT_MBINIT_REVMB);
    expect_state(LT_MBINIT_RPMB);
    expect_state(LT_MB_VALVREF);
    expect_state(LT_MB_DATAVREF);
    expect_state(LT_MB_SPEEDIDLE);
    expect_state(LT_MB_TXSELFCAL);
    expect_state(LT_MB_RXCLKCAL);
    expect_state(LT_MB_VTCENTER);
    expect_state(LT_MB_DTVREF1);
    expect_state(LT_MB_RXDESKEW);
    expect_state(LT_MB_DTCENTER2);
    expect_state(LT_MB_LINKSPEED);
    // REPAIR exits to LINKINIT when the partner signals done.
    fork
      begin
        wait (ltsm_state == LT_MB_REPAIR);
        // The response carries MS_LKS_DONE to accept the link.
        @(posedge sbclk);
      end
      begin
        repeat (200000) @(posedge lclk);
      end
    join_any

    // Reach ACTIVE.
    fork
      begin
        wait (link_trained);
        #0.1;
      end
      begin
        repeat (400000) @(posedge lclk);
      end
    join_any
    if (!link_trained) begin
      $display("FAIL ut_ltsm: did not reach ACTIVE, state %s",
               "%02h", ltsm_state);
      errors = errors + 1;
    end
    // Let the state recorder observe ACTIVE before the walk check.
    repeat (4) @(posedge lclk);
    if (train_error) begin
      $display("FAIL ut_ltsm: unexpected TRAINERROR");
      errors = errors + 1;
    end

    // The recorded walk must include every expected state in order.
    begin : walk_check
      ltsm_state_t exp_seq [0:20];
      int idx;
      exp_seq[0]  = LT_RESET;
      exp_seq[1]  = LT_SBINIT;
      exp_seq[2]  = LT_MBINIT_PARAM;
      exp_seq[3]  = LT_MBINIT_CAL;
      exp_seq[4]  = LT_MBINIT_RPCLK;
      exp_seq[5]  = LT_MBINIT_RPVAL;
      exp_seq[6]  = LT_MBINIT_REVMB;
      exp_seq[7]  = LT_MBINIT_RPMB;
      exp_seq[8]  = LT_MB_VALVREF;
      exp_seq[9]  = LT_MB_DATAVREF;
      exp_seq[10] = LT_MB_SPEEDIDLE;
      exp_seq[11] = LT_MB_TXSELFCAL;
      exp_seq[12] = LT_MB_RXCLKCAL;
      exp_seq[13] = LT_MB_VTCENTER;
      exp_seq[14] = LT_MB_DTVREF1;
      exp_seq[15] = LT_MB_RXDESKEW;
      exp_seq[16] = LT_MB_DTCENTER2;
      exp_seq[17] = LT_MB_LINKSPEED;
      exp_seq[18] = LT_MB_REPAIR;
      exp_seq[19] = LT_LINKINIT;
      exp_seq[20] = LT_ACTIVE;
      idx = 0;
      for (int i = 0; i < seen_n; i = i + 1) begin
        if (seen[i] == exp_seq[idx]) idx = idx + 1;
        if (idx == 21) i = seen_n;
      end
      if (idx != 21) begin
        $display("FAIL ut_ltsm: state walk incomplete, matched %0d of 21", idx);
        errors = errors + 1;
      end
    end

    if (errors == 0) $display("TEST PASSED ut_ltsm");
    else             $display("FAIL ut_ltsm: %0d errors", errors);
    $finish;
  end

  initial begin
    #100000000;
    $display("FAIL ut_ltsm: watchdog timeout, state %s", "%02h", ltsm_state);
    $finish;
  end

endmodule
