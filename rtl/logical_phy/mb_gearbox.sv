// ============================================================================
// File        : mb_gearbox.sv
// Project     : UCIe 1.0 Simplified Endpoint
// Description : Continuous-profile x16 mainband DDR word gearboxes.
//
// PHYSICAL PROFILE
// ~~~~~~~~~~~~~~~~
// The supported profile has sixteen lanes, sixteen bytes, and eight UIs per word.
// The local source runs continuously at 2 GHz before hardware reset release.
// The link clock runs at 500 MHz with an independent phase.
// The physical receive clock is the peer forwarded clock, not the local source.
// Each lane carries one byte, least significant bit first.
// Lane L at UI U carries word bit 8*L+U.
// One word takes four source cycles, or 2 ns at the supported rate.
// Parameter names remain available for the existing module interface.
// They do not advertise a different physical speed or an unsupported profile.
//
// TRANSMIT CONTRACT
// ~~~~~~~~~~~~~~~~~
// tx_ready qualifies a free FIFO entry after local reset release.
// Only tx_load AND tx_valid AND tx_ready writes a word.
// The depth-eight Gray FIFO crosses each word from lclk to the local source.
// tx_enable crosses through two source-domain registers.
// Permission controls FIFO consumption, not the local source clock.
// A queued isolated word starts as soon as permission and a readable head exist.
// No two-word priming requirement delays an isolated word.
// A busy serializer consumes the next head at the next four-cycle boundary.
// The first pair comes directly from the current FIFO head at its consume edge.
// The remaining pairs come from the saved word.
// Dedicated DDR cells capture each pair before serializer state advances.
// This order sustains one word per 2 ns without losing an odd UI.
// Disabled permission discards an in-flight partial word but preserves queued words.
// An epoch reset discards the queue and all serializer state.
// Permission must stay low until the controller acknowledges physical RUN.
//
// RECEIVE CONTRACT
// ~~~~~~~~~~~~~~~~
// Dedicated DDR cells capture both data and Valid at every ending UI edge.
// The receive parser processes both captured UIs in their physical order.
// It does not align a word to a reset counter or a local source phase.
// After release, the parser first observes a real low Valid UI.
// The next high Valid UI starts bit zero of a new word.
// This rule discards a frame that began before capture permission or epoch release.
// Each word must contain four high Valid UIs followed by four low Valid UIs.
// The parser also accepts a word that starts on the odd UI of a captured pair.
// A corrupt word never enters the receive FIFO.
// Legal whole words enter the depth-eight Gray FIFO once at their final UI.
// The local lclk consumes each readable FIFO head once.
// A stopped physical receive clock cannot repeat the last source-domain word.
// Buffered complete words can still drain after that clock stops.
//
// RESET AND EPOCH CONTRACT
// ~~~~~~~~~~~~~~~~~~~~~~~~
// Hardware and epoch resets assert one common reset across both FIFO domains.
// Each clock domain releases reset after two of its own rising edges.
// Neither gearbox independently clears just one FIFO pointer.
// RX capture disable also asserts this common receive reset.
// It discards queued words, a partial frame, and paired capture state immediately.
// A stopped physical receive clock cannot prevent that discard.
// A new receive epoch requires captured idle before the first wanted frame.
// Integration must retain its quiet interval before new scrambled user traffic.
// RX domain release can await physical edges without delaying sideband progress.
//
// FAULT CONTRACT
// ~~~~~~~~~~~~~~
// framing_fault records an illegal four-high, four-low receive frame.
// overflow records a complete legal word rejected by a full receive FIFO.
// Both flags clear only on hardware reset, not an epoch reset or capture disable.
// The integration layer synchronizes these flags into its fatal policy.
// FIFO full is ordinary transmit backpressure, not a transmit framing fault.
// There is no rate correction for indefinitely unequal average die frequencies.
//
// SPECIFICATION REFERENCES
// ~~~~~~~~~~~~~~~~~~~~~~~~
// UCIe 1.0 Section 4.1.1 defines byte lanes and DDR bit order.
// UCIe 1.0 Section 4.1.2 defines Valid framing.
// UCIe 1.0 Sections 5.2 and 8.1.2 define mainband source and link clocks.
//
// --------------------------------------------------------------------------
// Revision History
// --------------------------------------------------------------------------
//   v0.0.1  2026-09-23  Initial TX and RX gearboxes.
//   v0.0.4  2026-09-25  Phase E: add sticky framing history.
//   v0.0.8  2026-10-09  Add mainband asynchronous FIFOs.
//   v0.0.9  2026-10-09  Implement epoch, permission, and ready APIs.
//                       Use DDR cells and receive-Valid-based UI alignment.
// ============================================================================

`include "ucie_pkg.sv"
`timescale 1ns/1ps
module tx_gearbox #(
  parameter int unsigned NBYTES = ucie_pkg::NBYTES,     // Parallel word bytes
  parameter int unsigned NLANES = ucie_pkg::NLANES_MAX, // Physical data lanes
  parameter int unsigned NSLICE = 8                    // UIs per lane byte
) (
  input  logic                 lclk,          // Local 500 MHz link clock
  input  logic                 lreset_n,      // Common hardware reset
  input  logic                 epoch_reset_n, // Common serializer and FIFO epoch
  input  logic                 mbclk,         // Ungated local 2 GHz source
  input  logic                 tx_enable,     // Stable physical-run/data permission
  input  logic [NBYTES*8-1:0]   tx_word,       // Word held through accepted write
  input  logic                 tx_valid,      // Real payload qualifier
  input  logic                 tx_load,       // Write request
  output logic                 tx_ready,      // Link-domain FIFO acceptance ready
  output wire [NLANES-1:0]     mb_tx_data,    // Physical DDR data samples
  output wire                  mb_tx_valid    // Physical four-high/four-low framing
);
  localparam int unsigned NCYC = NSLICE/2;
  localparam int unsigned CYC_W = $clog2(NCYC);
  logic common_reset_n;                            // Both-domain epoch assertion
  (* async_reg = "true" *) logic [1:0] lrelease_q; // Link reset release
  (* async_reg = "true" *) logic [1:0] mbrelease_q; // Source reset release
  logic tx_lreset_n;                               // Released link reset
  logic tx_mbreset_n;                              // Released source reset
  (* async_reg = "true" *) logic [1:0] enable_sync_q; // Source permission ranks
  logic fifo_winc;                                 // Accepted word write
  logic fifo_wfull;                                // Link-domain full flag
  logic fifo_rinc;                                 // Serializer head consume
  logic [NBYTES*8-1:0] fifo_rdata;                  // Current source-domain head
  logic fifo_rvalid;                               // Readable source-domain head
  logic [NBYTES*8-1:0] ser_q;                       // Saved in-flight word
  logic ser_active_q;                              // A saved word has remaining pairs
  logic [CYC_W-1:0] cyc_q;                         // Next saved-word pair index
  logic [NBYTES*8-1:0] send_word_w;                 // Word for the next DDR pair
  logic [CYC_W-1:0] send_cyc_w;                    // Pair index before the launch edge
  logic [NLANES-1:0] hi_w;                         // Even UI prepared for DDR cells
  logic [NLANES-1:0] lo_w;                         // Odd UI prepared for DDR cells
  logic valid_w;                                   // Valid for both UIs of this pair

  // Assert the serializer and both FIFO domains together.
  // Hardware reset and epoch reset have the same data-path discard semantics.
  // Permission alone does not flush queued transmit words.
  // Both local release chains observe this one common assertion.
  // No independent read-pointer or write-pointer flush exists.
  assign common_reset_n = lreset_n && epoch_reset_n;

  // Release the link-side acceptance path after two local rising edges.
  // The FIFO uses the same common assertion and release length.
  // tx_ready remains low throughout the release interval.
  // A reset-time producer request cannot enter the memory.
  // Source permission does not affect this write-domain release.
  always_ff @(posedge lclk or negedge common_reset_n) begin
    if (!common_reset_n) lrelease_q <= 2'b00;
    else lrelease_q <= {lrelease_q[0], 1'b1};
  end

  // Release source-domain serialization after two source rising edges.
  // The internal source continues even when the physical clock is parked.
  // Asynchronous assertion discards the saved in-flight word.
  // The read-side FIFO uses the same source release length.
  // This release does not require a second queued word.
  always_ff @(posedge mbclk or negedge common_reset_n) begin
    if (!common_reset_n) mbrelease_q <= 2'b00;
    else mbrelease_q <= {mbrelease_q[0], 1'b1};
  end

  // Select the link-domain synchronized release.
  // Common assertion clears this qualifier asynchronously.
  // The producer sees readiness only after local release.
  // The source clock cannot bypass write-domain reset.
  // The FIFO and acceptance path share the same epoch.
  assign tx_lreset_n = lrelease_q[1];

  // Select the source-domain synchronized release.
  // Common assertion clears this qualifier asynchronously.
  // Serializer state and its DDR cells share this release.
  // The source clock remains free-running throughout PARK.
  // Read permission adds its own two-register synchronization below.
  assign tx_mbreset_n = mbrelease_q[1];

  // Synchronize stable data-consumption permission into the local source.
  // Physical RUN acknowledgment must precede this permission at the caller.
  // A deasserted permission prevents further FIFO head consumption.
  // The serializer also discards an unfinished frame on deassertion.
  // Epoch assertion clears both synchronizer ranks immediately.
  always_ff @(posedge mbclk or negedge tx_mbreset_n) begin
    if (!tx_mbreset_n) enable_sync_q <= 2'b00;
    else enable_sync_q <= {enable_sync_q[0], tx_enable};
  end

  // Report exact FIFO acceptance readiness in the link domain.
  // Full backpressure is normal and must hold the producer word.
  // Reset release is part of acceptance, not just the full flag.
  // A disabled serializer can buffer words until its FIFO fills.
  // No almost-full or two-word priming threshold affects this output.
  assign tx_ready = tx_lreset_n && !fifo_wfull;

  // Qualify a complete transmit FIFO write with the public handshake.
  // The producer must hold its payload through this accepted link edge.
  // Invalid loads do not consume an entry.
  // Full requests remain unaccepted without corrupting stored words.
  // Integration advances its scrambler only for its accepted upstream transfer.
  assign fifo_winc = tx_load && tx_valid && tx_ready;

  // Cross complete words from the link clock to the ungated local source.
  // Both reset ports receive the identical common epoch assertion.
  // The FIFO presents its current head before the consume edge.
  // The serializer snapshots that head and launches its first pair together.
  // Registered Gray full and empty flags preserve bounded isolated-word access.
  mb_async_fifo #(.DATA_W(NBYTES*8), .DEPTH(8)) u_tx_fifo (
    .wclk(lclk),
    .wrst_n(common_reset_n),
    .winc(fifo_winc),
    .wdata(tx_word),
    .wfull(fifo_wfull),
    .walmost_full(),
    .woverflow(),
    .woverflow_pulse(),
    .rclk(mbclk),
    .rrst_n(common_reset_n),
    .rinc(fifo_rinc),
    .rdata(fifo_rdata),
    .rempty(),
    .rvalid(fifo_rvalid),
    .runderflow()
  );

  // Consume one head only when the next pair starts a new word.
  // A saved word uses its remaining three pairs without another FIFO read.
  // Deasserted permission never advances the read pointer.
  // An isolated readable word can start immediately without a fill threshold.
  // The next word starts one edge after the prior final pair with no idle pair.
  assign fifo_rinc = tx_mbreset_n && enable_sync_q[1] &&
                     !ser_active_q && fifo_rvalid;

  // Prepare the next pair before the rising-edge DDR cell capture.
  // The first pair uses the readable FIFO head directly.
  // Subsequent pairs use the serializer snapshot and its next-pair index.
  // Data and Valid stay zero while permission is low or no word exists.
  // The DDR cell saves the odd UI before this state advances.
  always @* begin
    send_word_w = ser_active_q ? ser_q : fifo_rdata;
    send_cyc_w = ser_active_q ? cyc_q : '0;
    hi_w = '0;
    lo_w = '0;
    valid_w = 1'b0;
    if (tx_mbreset_n && enable_sync_q[1] && (ser_active_q || fifo_rvalid)) begin
      for (int lane = 0; lane < NLANES; lane = lane+1) begin
        hi_w[lane] = send_word_w[8*lane + 2*int'(send_cyc_w)];
        lo_w[lane] = send_word_w[8*lane + 2*int'(send_cyc_w) + 1];
      end
      valid_w = (send_cyc_w < CYC_W'(NCYC/2));
    end
  end

  // Save a newly consumed word and advance exactly four pair launches.
  // The DDR cells sample the pre-edge pair, including the direct first head pair.
  // After the final pair, the next edge can consume the following head.
  // A permission stop discards only the unfinished snapshot.
  // Common epoch reset also discards every queued FIFO word.
  always_ff @(posedge mbclk or negedge tx_mbreset_n) begin
    if (!tx_mbreset_n) begin
      ser_q <= '0;
      ser_active_q <= 1'b0;
      cyc_q <= '0;
    end else if (!enable_sync_q[1]) begin
      ser_q <= '0;
      ser_active_q <= 1'b0;
      cyc_q <= '0;
    end else if (ser_active_q) begin
      if (cyc_q == CYC_W'(NCYC-1)) begin
        ser_active_q <= 1'b0;
        cyc_q <= '0;
      end else cyc_q <= cyc_q + CYC_W'(1);
    end else if (fifo_rvalid) begin
      ser_q <= fifo_rdata;
      ser_active_q <= 1'b1;
      cyc_q <= CYC_W'(1);
    end
  end

  for (genvar lane = 0; lane < NLANES; lane = lane+1) begin : g_tx_ddr
    // Launch this lane through the dedicated DDR physical cell model.
    // Even and odd samples come from the same prepared serializer pair.
    // The cell holds the odd sample across serializer state changes.
    // Its internal driver stays enabled because external pad OEs are separate.
    // The unused receive ports do not substitute for a physical receive clock.
    mb_ddr_io u_data_io (
      .clk(mbclk), .rst_n(tx_mbreset_n),
      .tx_data_hi(hi_w[lane]), .tx_data_lo(lo_w[lane]), .tx_oe(1'b1),
      .rx_data_hi(), .rx_data_lo(), .rx_pair_valid(),
      .pad_tx(mb_tx_data[lane]), .pad_rx(1'b0)
    );
  end

  // Launch Valid with the same edge semantics as each data lane.
  // A real word has two high pairs followed by two low pairs.
  // Both UIs in a pair use the same framing level.
  // There is no combinational serializer-counter path to the physical pin.
  // The controller clock gate remains independent of this signal.
  mb_ddr_io u_valid_io (
    .clk(mbclk), .rst_n(tx_mbreset_n),
    .tx_data_hi(valid_w), .tx_data_lo(valid_w), .tx_oe(1'b1),
    .rx_data_hi(), .rx_data_lo(), .rx_pair_valid(),
    .pad_tx(mb_tx_valid), .pad_rx(1'b0)
  );
endmodule

module rx_gearbox #(
  parameter int unsigned NBYTES = ucie_pkg::NBYTES,     // Parallel word bytes
  parameter int unsigned NLANES = ucie_pkg::NLANES_MAX, // Physical data lanes
  parameter int unsigned NSLICE = 8                    // UIs per lane byte
) (
  input  logic                 lclk,          // Local 500 MHz link clock
  input  logic                 lreset_n,      // Common hardware reset
  input  logic                 epoch_reset_n, // Common capture and FIFO epoch
  input  logic                 mbclk,         // Physical peer forwarded clock
  input  logic                 rx_enable,     // Capture permission with common discard
  input  logic                 rx_drain_enable, // Local complete-word dequeue permission
  input  logic [NLANES-1:0]     mb_rx_data,    // Physical peer DDR lane samples
  input  logic                 mb_rx_valid,   // Physical peer DDR Valid samples
  output logic [NBYTES*8-1:0]   rx_word,       // Complete local-domain word
  output logic                 rx_word_vld,   // One accepted FIFO head per lclk cycle
  output logic                 framing_fault, // Hardware-reset-only framing history
  output logic                 overflow       // Hardware-reset-only receive overflow
);
  localparam int unsigned UI_W = $clog2(NSLICE);
  logic common_reset_n;                            // Both-domain capture discard
  (* async_reg = "true" *) logic [1:0] lrelease_q; // Local output reset release
  (* async_reg = "true" *) logic [1:0] mbrelease_q; // Physical capture permission release
  logic rx_lreset_n;                               // Released local reset
  logic rx_mbreset_n;                              // Released physical capture reset
  wire [NLANES-1:0] pair_hi;                       // Captured even lane UIs
  wire [NLANES-1:0] pair_lo;                       // Captured odd lane UIs
  wire pair_valid_hi;                             // Captured even Valid UI
  wire pair_valid_lo;                             // Captured odd Valid UI
  wire pair_ready;                                // Complete physical pair exists
  logic armed_q;                                  // A real idle UI has been observed
  logic armed_next;                               // Next receive alignment arm
  logic frame_active_q;                           // A new frame has begun
  logic frame_active_next;                        // Next receive frame state
  logic frame_ok_q;                               // Frame pattern remains legal
  logic frame_ok_next;                            // Next pattern legality
  logic [UI_W-1:0] ui_q;                          // Next UI index within the frame
  logic [UI_W-1:0] ui_next;                        // Next parser UI index
  logic [NBYTES*8-1:0] asm_q;                      // Partial receive word
  logic [NBYTES*8-1:0] asm_next;                   // Partial word after both captured UIs
  logic [NBYTES*8-1:0] complete_word_w;            // Final word including the last UI
  logic [NLANES-1:0] ui_data_w;                    // Current captured UI in the parser
  logic ui_valid_w;                               // Current captured Valid in the parser
  logic frame_fault_w;                            // Current pair has a framing violation
  logic fifo_winc;                                // This pair completes one legal word
  logic fifo_wfull;                               // Physical-domain FIFO full flag
  logic fifo_rinc;                                // Local readable-head consume
  logic [NBYTES*8-1:0] fifo_rdata;                 // Local readable word head
  logic fifo_rvalid;                              // Local FIFO head qualifier

  // Discard the entire receive epoch when capture permission drops.
  // The same assertion reaches both FIFO pointers and the partial frame.
  // A stopped physical clock cannot retain stale queued words through disable.
  // Each domain synchronizes release when capture permission returns.
  // Sticky framing and overflow history use hardware reset separately.
  assign common_reset_n = lreset_n && epoch_reset_n && rx_enable;

  // Release the local receive output path after two lclk rising edges.
  // Assertion clears output validity immediately.
  // The FIFO read side uses the same common reset and release length.
  // The physical receive clock does not delay local reset assertion.
  // Words remain invalid until a complete new physical frame reaches the FIFO.
  always_ff @(posedge lclk or negedge common_reset_n) begin
    if (!common_reset_n) lrelease_q <= 2'b00;
    else lrelease_q <= {lrelease_q[0], 1'b1};
  end

  // Synchronize capture permission release into the physical clock domain.
  // Permission disable asserts this chain and both FIFO domains asynchronously.
  // Two physical rising edges precede any new capture state.
  // A stopped physical clock can delay release without affecting sideband logic.
  // The parser must then observe captured low Valid before a new wanted frame.
  always_ff @(posedge mbclk or negedge common_reset_n) begin
    if (!common_reset_n) mbrelease_q <= 2'b00;
    else mbrelease_q <= {mbrelease_q[0], 1'b1};
  end

  // Select local synchronized reset release for the output register.
  // Common assertion invalidates the output without a local edge.
  // A read transfer requires both this release and the FIFO head qualifier.
  // Epoch discard never resets only the local pointer.
  // Sticky hardware fault history is independent of this signal.
  assign rx_lreset_n = lrelease_q[1];

  // Select physical synchronized reset release for capture and parsing.
  // The peer forwarded clock is the only clock for this release.
  // The local source clock cannot invent a received UI.
  // An unfinished capture pair disappears on common assertion.
  // A new legal frame requires a physical low-to-high Valid boundary.
  assign rx_mbreset_n = mbrelease_q[1];

  for (genvar lane = 0; lane < NLANES; lane = lane+1) begin : g_rx_ddr
    // Capture this lane from the dedicated peer physical input pin.
    // The physical forwarded clock samples both ending UI edges.
    // The paired outputs retain even-before-odd order.
    // The transmit side of this input-cell instance stays disabled.
    // No reset counter supplies synthetic data or clock alignment.
    mb_ddr_io u_data_io (
      .clk(mbclk), .rst_n(rx_mbreset_n),
      .tx_data_hi(1'b0), .tx_data_lo(1'b0), .tx_oe(1'b0),
      .rx_data_hi(pair_hi[lane]), .rx_data_lo(pair_lo[lane]), .rx_pair_valid(),
      .pad_tx(), .pad_rx(mb_rx_data[lane])
    );
  end

  // Capture Valid through the same physical DDR boundary as the data lanes.
  // Separate even and odd levels detect half-cycle framing changes.
  // Pair validity excludes the first incomplete pair after reset release.
  // A stopped receive clock leaves only a source-domain held pair.
  // The word FIFO, not a held pair level, drives local output transfers.
  mb_ddr_io u_valid_io (
    .clk(mbclk), .rst_n(rx_mbreset_n),
    .tx_data_hi(1'b0), .tx_data_lo(1'b0), .tx_oe(1'b0),
    .rx_data_hi(pair_valid_hi), .rx_data_lo(pair_valid_lo), .rx_pair_valid(pair_ready),
    .pad_tx(), .pad_rx(mb_rx_valid)
  );

  // Parse the two captured physical UIs in their received order.
  // A real idle UI arms alignment before the next high Valid UI.
  // Every active frame checks four high and four low UIs, including odd edges.
  // A final UI can complete one frame before the other UI starts the next.
  // The final assembled value writes the FIFO once on this physical rising edge.
  always_comb begin
    armed_next = armed_q;
    frame_active_next = frame_active_q;
    frame_ok_next = frame_ok_q;
    ui_next = ui_q;
    asm_next = asm_q;
    complete_word_w = '0;
    fifo_winc = 1'b0;
    frame_fault_w = 1'b0;
    ui_data_w = '0;
    ui_valid_w = 1'b0;
    if (rx_mbreset_n && pair_ready) begin
      for (int pair_ui = 0; pair_ui < 2; pair_ui = pair_ui+1) begin
        ui_data_w = (pair_ui == 0) ? pair_hi : pair_lo;
        ui_valid_w = (pair_ui == 0) ? pair_valid_hi : pair_valid_lo;
        if (!frame_active_next) begin
          if (!armed_next) begin
            if (ui_valid_w == 1'b0) armed_next = 1'b1;
          end else if (ui_valid_w == 1'b1) begin
            asm_next = '0;
            for (int lane = 0; lane < NLANES; lane = lane+1) begin
              asm_next[8*lane] = ui_data_w[lane];
            end
            frame_active_next = 1'b1;
            frame_ok_next = 1'b1;
            ui_next = UI_W'(1);
          end
        end else begin
          if (ui_valid_w !== (ui_next < UI_W'(NSLICE/2))) begin
            frame_ok_next = 1'b0;
            frame_fault_w = 1'b1;
          end
          for (int lane = 0; lane < NLANES; lane = lane+1) begin
            asm_next[8*lane + int'(ui_next)] = ui_data_w[lane];
          end
          if (ui_next == UI_W'(NSLICE-1)) begin
            if (frame_ok_next) begin
              complete_word_w = asm_next;
              fifo_winc = 1'b1;
            end
            frame_active_next = 1'b0;
            armed_next = (ui_valid_w === 1'b0);
            ui_next = '0;
          end else ui_next = ui_next + UI_W'(1);
        end
      end
    end
  end

  // Save parser state once per complete physical clock cycle.
  // Both captured UIs already contributed to the combinational next state.
  // Common reset discards partial words and observed-idle alignment.
  // No fixed reset phase counter determines a frame start.
  // The separate FIFO write uses the same pre-edge completed-word calculation.
  always_ff @(posedge mbclk or negedge rx_mbreset_n) begin
    if (!rx_mbreset_n) begin
      armed_q <= 1'b0;
      frame_active_q <= 1'b0;
      frame_ok_q <= 1'b0;
      ui_q <= '0;
      asm_q <= '0;
    end else begin
      armed_q <= armed_next;
      frame_active_q <= frame_active_next;
      frame_ok_q <= frame_ok_next;
      ui_q <= ui_next;
      asm_q <= asm_next;
    end
  end

  // Keep hardware-reset-only receive fault history.
  // Epoch reset and capture disable suppress events but never clear old faults.
  // Framing faults arise from a captured UI, not a local phase estimate.
  // Overflow records the exact legal-word write rejected by the full FIFO.
  // Integration synchronizes these source-domain sticky levels into lclk.
  always_ff @(posedge mbclk or negedge lreset_n) begin
    if (!lreset_n) begin
      framing_fault <= 1'b0;
      overflow <= 1'b0;
    end else if (rx_mbreset_n) begin
      if (frame_fault_w) framing_fault <= 1'b1;
      if (fifo_winc && fifo_wfull) overflow <= 1'b1;
    end
  end

  // Cross only complete legal words from the peer physical clock into lclk.
  // The write data includes the last captured UI of the word.
  // A full FIFO rejects the write without changing memory or pointers.
  // Both reset ports receive the identical common capture-epoch assertion.
  // Read-head semantics support one local consume edge per delivered word.
  mb_async_fifo #(.DATA_W(NBYTES*8), .DEPTH(8)) u_rx_fifo (
    .wclk(mbclk),
    .wrst_n(common_reset_n),
    .winc(fifo_winc),
    .wdata(complete_word_w),
    .wfull(fifo_wfull),
    .walmost_full(),
    .woverflow(),
    .woverflow_pulse(),
    .rclk(lclk),
    .rrst_n(common_reset_n),
    .rinc(fifo_rinc),
    .rdata(fifo_rdata),
    .rempty(),
    .rvalid(fifo_rvalid),
    .runderflow()
  );

  // Consume each readable local FIFO head without a source-level valid echo.
  // A read is accepted only after local reset release.
  // The accepted edge advances the Gray read pointer once.
  // A stopped physical clock leaves a finite queue that drains to empty.
  // The same head cannot produce another output after its accepted read.
  assign fifo_rinc = rx_lreset_n && rx_drain_enable && fifo_rvalid;

  // Register one output transfer per accepted local FIFO head.
  // Consecutive legal words can produce consecutive qualified lclk cycles.
  // The empty flag ends output validity after the final buffered word.
  // Common assertion clears output validity even with a stopped peer clock.
  // No source-domain held word-valid level drives this output directly.
  always_ff @(posedge lclk or negedge rx_lreset_n) begin
    if (!rx_lreset_n) begin
      rx_word <= '0;
      rx_word_vld <= 1'b0;
    end else begin
      rx_word_vld <= fifo_rinc;
      if (fifo_rinc) rx_word <= fifo_rdata;
    end
  end
endmodule
