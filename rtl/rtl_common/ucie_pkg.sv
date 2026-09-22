// UCIe 1.0 Simplified Endpoint - shared package
// Standard Package x16, Streaming / Raw Mode (Format 1), 4 GT/s.
// Single source of truth for all constants. See doc/PLAN.md.
`ifndef UciePkg_SV
`define UciePkg_SV

package ucie_pkg;

  // ---------------------------------------------------------------- clocks
  // Spec: sideband 800 MHz, main band 2 GHz, lclk 1 GHz (4 GT/s only).
  localparam int unsigned CLK_SB_HZ    = 32'd800_000_000;
  localparam int unsigned LCLK_HZ      = 32'd1_000_000_000;

  // ------------------------------------------------------- data bus widths
  // NBYTES is per-instance; default 16 B matches x16 Standard Package.
  localparam int unsigned NBYTES    = 16;
  localparam int unsigned DATA_W    = NBYTES * 8;
  localparam int unsigned NC        = 8;   // sideband cfg interface width

  // -------------------------------------------------------------- timers
  // True to spec. README forbids faster simulation timers.
  localparam int unsigned T_RESET_MIN_NS = 32'd4_000_000;   // 4 ms
  localparam int unsigned T_RESIDENCY_NS = 32'd8_000_000;   // 8 ms per sub-state
  localparam int unsigned T_SB_MSG_NS    = 32'd8_000_000;   // 8 ms message timeout
  localparam int unsigned T_STALL_NS     = 32'd4_000_000;   // stall every 4 ms

  // Lclk cycle counts (1 ns per cycle at 1 GHz).
  localparam int unsigned C_RESET_MIN = T_RESET_MIN_NS;
  localparam int unsigned C_RESIDENCY = T_RESIDENCY_NS;
  localparam int unsigned C_SB_MSG    = T_SB_MSG_NS;
  localparam int unsigned C_STALL     = T_STALL_NS;

  // Sideband framing.
  localparam int unsigned SB_PKT_BITS  = 64;
  localparam int unsigned SB_GAP_UI    = 32;

  // Training pattern sizes.
  localparam int unsigned VALTRAIN_ITER   = 128;
  localparam int unsigned VALTRAIN_DETECT = 16;
  localparam int unsigned LFSR_PATTERN_UI = 4096;

  typedef logic [2:0] pat_t;
  localparam pat_t PAT_PERLANEID = 3'd0;
  localparam pat_t PAT_VALTRAIN  = 3'd1;
  localparam pat_t PAT_CLKREPAIR = 3'd2;
  localparam pat_t PAT_LFSR      = 3'd3;

  // ---------------------------------------------------------------- lanes
  localparam int unsigned NLANES_MAX = 16;
  localparam int unsigned NLANES_X8  = 8;

  // LFSR G(x) = x^23 + x^21 + x^16 + x^8 + x^5 + x^2 + 1  (spec 4.4.1)
  // The register shifts right with feedback into bit 22, so register bit k at time t
  // is output bit t+k and the realised recurrence is o(t+23) = XOR of o(t+i) over the
  // tapped bits. Taps {21,16,8,5,2,0} therefore give exactly the spec polynomial;
  // x^23 is the shift itself and has no bit in a 23-bit mask.
  localparam int unsigned LFSR_W   = 23;
  localparam logic [LFSR_W-1:0] LFSR_TAPS = 23'h210125;

  // Per-lane seed = lane number mod 8. Icarus Verilog does not accept an array
  // assignment pattern in a localparam, so the table is a function instead.
  function automatic logic [LFSR_W-1:0] lfsr_seed(input int unsigned lane);
    case (lane % 8)
      8'd0: lfsr_seed = 23'h1DBFBC;
      8'd1: lfsr_seed = 23'h0607BB;
      8'd2: lfsr_seed = 23'h1EC760;
      8'd3: lfsr_seed = 23'h18C0DB;
      8'd4: lfsr_seed = 23'h010F12;
      8'd5: lfsr_seed = 23'h19CFC9;
      8'd6: lfsr_seed = 23'h0277CE;
      8'd7: lfsr_seed = 23'h1BB807;
      default: lfsr_seed = 23'h1DBFBC;
    endcase
  endfunction

  // ------------------------------------------------------------ RDI states
  // Table 114: lp_state_req encodings.
  typedef logic [3:0] rdi_req_t;
  localparam rdi_req_t RDI_REQ_NOP      = 4'h0;
  localparam rdi_req_t RDI_REQ_ACTIVE   = 4'h1;
  localparam rdi_req_t RDI_REQ_L1       = 4'h4;
  localparam rdi_req_t RDI_REQ_L2       = 4'h8;
  localparam rdi_req_t RDI_REQ_LINKRESET= 4'h9;
  localparam rdi_req_t RDI_REQ_RETRAIN  = 4'hB;
  localparam rdi_req_t RDI_REQ_DISABLED = 4'hC;

  // Table 114: pl_state_sts encodings.
  typedef logic [3:0] rdi_sts_t;
  localparam rdi_sts_t RDI_STS_RESET    = 4'h0;
  localparam rdi_sts_t RDI_STS_ACTIVE   = 4'h1;
  localparam rdi_sts_t RDI_STS_PMNAK    = 4'h3;
  localparam rdi_sts_t RDI_STS_L1       = 4'h4;
  localparam rdi_sts_t RDI_STS_L2       = 4'h8;
  localparam rdi_sts_t RDI_STS_LINKRESET= 4'h9;
  localparam rdi_sts_t RDI_STS_LINKERROR= 4'hA;
  localparam rdi_sts_t RDI_STS_RETRAIN  = 4'hB;
  localparam rdi_sts_t RDI_STS_DISABLED = 4'hC;

  // ------------------------------------------------------------ FDI states
  // Table 115: identical encodings to RDI.
  localparam rdi_req_t FDI_REQ_NOP      = RDI_REQ_NOP;
  localparam rdi_req_t FDI_REQ_ACTIVE   = RDI_REQ_ACTIVE;
  localparam rdi_req_t FDI_REQ_L1       = RDI_REQ_L1;
  localparam rdi_req_t FDI_REQ_L2       = RDI_REQ_L2;
  localparam rdi_req_t FDI_REQ_LINKRESET= RDI_REQ_LINKRESET;
  localparam rdi_req_t FDI_REQ_RETRAIN  = RDI_REQ_RETRAIN;
  localparam rdi_req_t FDI_REQ_DISABLED = RDI_REQ_DISABLED;

  localparam rdi_sts_t FDI_STS_RESET    = RDI_STS_RESET;
  localparam rdi_sts_t FDI_STS_ACTIVE   = RDI_STS_ACTIVE;
  localparam rdi_sts_t FDI_STS_PMNAK    = RDI_STS_PMNAK;
  localparam rdi_sts_t FDI_STS_L1       = RDI_STS_L1;
  localparam rdi_sts_t FDI_STS_L2       = RDI_STS_L2;
  localparam rdi_sts_t FDI_STS_LINKRESET= RDI_STS_LINKRESET;
  localparam rdi_sts_t FDI_STS_LINKERROR= RDI_STS_LINKERROR;
  localparam rdi_sts_t FDI_STS_RETRAIN  = RDI_STS_RETRAIN;
  localparam rdi_sts_t FDI_STS_DISABLED = RDI_STS_DISABLED;

  // ------------------------------------------------------- speed / width
  // pl_speedmode: 000 = 4 GT/s (only supported value).
  typedef logic [2:0] speed_t;
  localparam speed_t SPEED_4GT = 3'b000;

  // pl_lnk_cfg.
  typedef logic [2:0] lnkcfg_t;
  localparam lnkcfg_t LNKCFG_X8  = 3'b001;
  localparam lnkcfg_t LNKCFG_X16 = 3'b010;

  // -------------------------------------------------- negotiated protocol
  // pl_protocol: 111 = Streaming Protocol.
  typedef logic [2:0] proto_t;
  localparam proto_t PROTO_STREAMING = 3'b111;

  // pl_protocol_flitfmt: 0001 = Format 1 Raw Mode.
  typedef logic [3:0] flitfmt_t;
  localparam flitfmt_t FMT_RAW = 4'b0001;

  // lp_stream / pl_stream: 04h = Stack 0 Streaming.
  localparam logic [7:0] STREAM_ID_S0_STREAMING = 8'h04;

  // ------------------------------------------------------------ sideband
  // Table 47 opcodes.
  typedef logic [4:0] sb_opcode_t;
  localparam sb_opcode_t SB_OP_MSG_NODATA = 5'b10010; // message without data
  localparam sb_opcode_t SB_OP_MSG_DATA64 = 5'b11011; // message with 64b data

  // srcid / dstid (Table 49), RDI side.
  typedef logic [2:0] sb_srcid_t;
  localparam sb_srcid_t SRCID_STACK0 = 3'b000;
  localparam sb_srcid_t SRCID_ADAPT  = 3'b001;

  // ---------------------------------------------------- LTSM state encodings
  // Error Log 0 "State N".
  typedef logic [7:0] ltsm_state_t;
  localparam ltsm_state_t LT_RESET          = 8'h00;
  localparam ltsm_state_t LT_SBINIT         = 8'h01;
  localparam ltsm_state_t LT_MBINIT_PARAM   = 8'h02;
  localparam ltsm_state_t LT_MBINIT_CAL     = 8'h03;
  localparam ltsm_state_t LT_MBINIT_RPCLK   = 8'h04;
  localparam ltsm_state_t LT_MBINIT_RPVAL   = 8'h05;
  localparam ltsm_state_t LT_MBINIT_REVMB   = 8'h06;
  localparam ltsm_state_t LT_MBINIT_RPMB    = 8'h07;
  localparam ltsm_state_t LT_MB_VALVREF     = 8'h08;
  localparam ltsm_state_t LT_MB_DATAVREF    = 8'h09;
  localparam ltsm_state_t LT_MB_SPEEDIDLE   = 8'h0A;
  localparam ltsm_state_t LT_MB_TXSELFCAL   = 8'h0B;
  localparam ltsm_state_t LT_MB_RXCLKCAL    = 8'h0C;
  localparam ltsm_state_t LT_MB_VTCENTER    = 8'h0D;
  localparam ltsm_state_t LT_MB_DTVREF1     = 8'h0E;
  localparam ltsm_state_t LT_MB_RXDESKEW    = 8'h0F;
  localparam ltsm_state_t LT_MB_DTCENTER2   = 8'h10;
  localparam ltsm_state_t LT_MB_LINKSPEED   = 8'h11;
  localparam ltsm_state_t LT_MB_REPAIR      = 8'h12;
  localparam ltsm_state_t LT_PHYRETRAIN     = 8'h13;
  localparam ltsm_state_t LT_LINKINIT       = 8'h14;
  localparam ltsm_state_t LT_ACTIVE         = 8'h15;
  localparam ltsm_state_t LT_TRAINERROR     = 8'h16;
  localparam ltsm_state_t LT_L1L2           = 8'h17;
  localparam int unsigned LT_NUM_STATES     = 24;

  // -------------------------------------------------- sideband message codes
  // Tables 53, 54, 56. {code, subcode} pairs used by this project.
  // Link management.
  localparam logic [7:0] MC_NOP_CRD        = 8'h00;
  localparam logic [7:0] MC_LM_RDI_REQ     = 8'h01;
  localparam logic [7:0] MC_LM_RDI_RSP     = 8'h02;
  localparam logic [7:0] MC_ADVCAP_ADAPTER = 8'h01;
  localparam logic [7:0] MC_FINCAP_ADAPTER = 8'h02;
  localparam logic [7:0] MC_ERRMSG         = 8'h09;

  // LinkMgmt.RDI subcodes (state value).
  localparam logic [7:0] MS_LM_ACTIVE      = 8'h01;
  localparam logic [7:0] MS_LM_PMNAK       = 8'h02;
  localparam logic [7:0] MS_LM_L1          = 8'h04;
  localparam logic [7:0] MS_LM_L2          = 8'h08;
  localparam logic [7:0] MS_LM_LINKRESET   = 8'h09;
  localparam logic [7:0] MS_LM_LINKERROR   = 8'h0A;
  localparam logic [7:0] MS_LM_RETRAIN     = 8'h0B;
  localparam logic [7:0] MS_LM_DISABLE     = 8'h0C;

  // SBINIT.
  localparam logic [7:0] MC_SB_OOB_RESET   = 8'h91;
  localparam logic [7:0] MC_SB_DONE_REQ    = 8'h95;
  localparam logic [7:0] MC_SB_DONE_RSP    = 8'h9A;

  // MBINIT: req A5h / resp AAh.
  localparam logic [7:0] MC_MBINIT_REQ     = 8'hA5;
  localparam logic [7:0] MC_MBINIT_RSP     = 8'hAA;
  localparam logic [7:0] MS_PARAM_CFG      = 8'h00;
  localparam logic [7:0] MS_CAL_DONE       = 8'h02;
  localparam logic [7:0] MS_RPCLK_INIT     = 8'h03;
  localparam logic [7:0] MS_RPCLK_RESULT   = 8'h04;
  localparam logic [7:0] MS_RPCLK_APPLY    = 8'h05;
  localparam logic [7:0] MS_RPCLK_CHKINI   = 8'h06;
  localparam logic [7:0] MS_RPCLK_CHKRES   = 8'h07;
  localparam logic [7:0] MS_RPCLK_DONE     = 8'h08;
  localparam logic [7:0] MS_RPVAL_INIT     = 8'h09;
  localparam logic [7:0] MS_RPVAL_RESULT   = 8'h0A;
  localparam logic [7:0] MS_RPVAL_APPLY    = 8'h0B;
  localparam logic [7:0] MS_RPVAL_DONE     = 8'h0C;
  localparam logic [7:0] MS_REVMB_INIT     = 8'h0D;
  localparam logic [7:0] MS_REVMB_CLRERR   = 8'h0E;
  localparam logic [7:0] MS_REVMB_RESULT   = 8'h0F;
  localparam logic [7:0] MS_REVMB_DONE     = 8'h10;
  localparam logic [7:0] MS_RPMB_START     = 8'h11;
  localparam logic [7:0] MS_RPMB_APPLY     = 8'h12;
  localparam logic [7:0] MS_RPMB_END       = 8'h13;
  localparam logic [7:0] MS_RPMB_END2      = 8'h14;

  // MBTRAIN: req B5h / resp BAh.
  localparam logic [7:0] MC_MBTRAIN_REQ    = 8'hB5;
  localparam logic [7:0] MC_MBTRAIN_RSP    = 8'hBA;
  localparam logic [7:0] MS_VALVREF_START  = 8'h00;
  localparam logic [7:0] MS_VALVREF_END    = 8'h01;
  localparam logic [7:0] MS_DATAVREF_START = 8'h02;
  localparam logic [7:0] MS_DATAVREF_END   = 8'h03;
  localparam logic [7:0] MS_SPEEDIDLE_DONE = 8'h04;
  localparam logic [7:0] MS_TXSELFCAL_DONE = 8'h05;
  localparam logic [7:0] MS_RXCLKCAL_START = 8'h06;
  localparam logic [7:0] MS_RXCLKCAL_DONE  = 8'h07;
  localparam logic [7:0] MS_VTC_START      = 8'h08;
  localparam logic [7:0] MS_VTC_DONE       = 8'h09;
  localparam logic [7:0] MS_VTV_START      = 8'h0A;
  localparam logic [7:0] MS_VTV_END        = 8'h0B;
  localparam logic [7:0] MS_DTC1_START     = 8'h0C;
  localparam logic [7:0] MS_DTC1_END       = 8'h0D;
  localparam logic [7:0] MS_DTV_START      = 8'h0E;
  localparam logic [7:0] MS_DTV_END        = 8'h10;
  localparam logic [7:0] MS_DESKEW_START   = 8'h11;
  localparam logic [7:0] MS_DESKEW_END     = 8'h12;
  localparam logic [7:0] MS_DTC2_START     = 8'h13;
  localparam logic [7:0] MS_DTC2_END       = 8'h14;
  localparam logic [7:0] MS_LKS_START      = 8'h15;
  localparam logic [7:0] MS_LKS_ERROR      = 8'h16;
  localparam logic [7:0] MS_LKS_EXIT_REP   = 8'h17;
  localparam logic [7:0] MS_LKS_EXIT_DEG   = 8'h18;
  localparam logic [7:0] MS_LKS_DONE       = 8'h19;
  localparam logic [7:0] MS_LKS_MM_DIS     = 8'h1A;
  localparam logic [7:0] MS_LKS_EXIT_PHY   = 8'h1F;
  localparam logic [7:0] MS_REPAIR_INIT    = 8'h1B;
  localparam logic [7:0] MS_REPAIR_APPLY   = 8'h1C;
  localparam logic [7:0] MS_REPAIR_END     = 8'h1D;
  localparam logic [7:0] MS_REPAIR_DEGRADE = 8'h1E;

  // PHYRETRAIN: req C5h / resp CAh.
  localparam logic [7:0] MC_PHYR_REQ       = 8'hC5;
  localparam logic [7:0] MC_PHYR_RSP       = 8'hCA;
  localparam logic [7:0] MS_PHYR_INIT      = 8'h00;
  localparam logic [7:0] MS_PHYR_START     = 8'h01;

  // TRAINERROR: req E5h / resp EAh.
  localparam logic [7:0] MC_TE_REQ         = 8'hE5;
  localparam logic [7:0] MC_TE_RSP         = 8'hEA;
  localparam logic [7:0] MS_TE_ENTRY       = 8'h00;

  // AdvCap.Adapter data payload bits.
  localparam int unsigned ADV_RAW_MODE     = 0;
  localparam int unsigned ADV_STREAMING    = 4;
  localparam int unsigned ADV_STACK0_EN    = 7;
  localparam int unsigned ADV_RETIMER      = 11;
  localparam int unsigned ADV_RTM_CRD_LO   = 12;
  localparam int unsigned ADV_RTM_CRD_HI   = 20;
  localparam int unsigned ADV_DP           = 21;
  localparam int unsigned ADV_UP           = 22;

  // Width degrade lane map (Apply degrade req MsgInfo [1:0]).
  localparam logic [1:0] DEGRADE_LANES_0_7  = 2'b01;
  localparam logic [1:0] DEGRADE_LANES_8_15 = 2'b10;

  // Credit loop limits (spec 6.1.3): max 4 outstanding remote.
  localparam int unsigned SB_CRD_MAX = 4;

endpackage

`endif
