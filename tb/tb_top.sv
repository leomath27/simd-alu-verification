// Constrained-random, self-checking testbench for simd_alu.
//
//  generator (phased scenarios) -> driver -> DUT -> monitor -> scoreboard
//                                                  \-> reference model / coverage
//  + SVA suite bound into the DUT (sva/simd_alu_sva.sv)
//
// Plusargs: +seed=N  +cycles=N (per phase)  +nobias (pure uniform-random operands)  +quiet
`timescale 1ns/1ps
module tb_top;
  import simd_defs_pkg::*;
  import simd_tb_pkg::*;

  // ------------------------------ DUT ------------------------------
  logic        clk = 0, rst_n = 0;
  logic        in_valid = 0, stall = 0;
  logic [4:0]  op = 0;
  logic [1:0]  sew = 0;
  logic [63:0] a = 0, b = 0;
  logic        out_valid, illegal;
  logic [63:0] result;
  logic [7:0]  flags;

  simd_alu dut (.*);

  always #5 clk = ~clk;

  // ------------------------------ scoreboard ------------------------------
  typedef struct {
    logic [63:0] res, a, b;
    logic [7:0]  flg;
    logic        ill;
    logic [4:0]  op;
    logic [1:0]  sew;
    longint unsigned t;
  } exp_t;

  exp_t exp_q[$];
  longint unsigned cyc = 0;
  int unsigned n_accept = 0, n_check = 0, n_stalled_offer = 0, n_reset = 0, n_bubble = 0;
  int unsigned sb_err = 0, valid_err = 0, flag_err = 0, ill_err = 0, data_err = 0, spurious = 0;
  bit  quiet = 0;

  // cycle-accurate model of the pipeline occupancy (checks out_valid every cycle)
  logic m_s1 = 0, m_out = 0;
  // coverage helpers
  int unsigned acc_run = 0, hold_run = 0;
  logic        prev_accept = 0, prev_stall = 0, prev_rst_n = 1;
  logic [4:0]  prev_op = 0;
  bit          have_prev_op = 0;
  bit          gap_after_accept = 0;

  always @(posedge clk) begin
    exp_t e;
    logic [63:0] r;  logic [7:0] f;  logic il;
    cyc <= cyc + 1;

    // (1) valid-pipeline model vs DUT
    if (out_valid !== m_out) begin
      valid_err++;  sb_err++;
      if (!quiet && valid_err <= 5) $display("[SB] cyc %0d: out_valid=%0b expected %0b", cyc, out_valid, m_out);
    end

    // (2) consume an output
    if (out_valid && !stall) begin
      if (exp_q.size() == 0) begin
        spurious++; sb_err++;
        if (!quiet && spurious <= 5) $display("[SB] cyc %0d: spurious output (no expected transaction)", cyc);
      end else begin
        e = exp_q.pop_front();
        n_check++;
        if (result !== e.res || flags !== e.flg || illegal !== e.ill) begin
          sb_err++;
          if (result !== e.res)   data_err++;
          if (flags  !== e.flg)   flag_err++;
          if (illegal !== e.ill)  ill_err++;
          if (!quiet && sb_err <= 8)
            $display("[SB] MISMATCH op=%0d sew=%0d a=%h b=%h | got res=%h flg=%h ill=%0b | exp res=%h flg=%h ill=%0b",
                     e.op, e.sew, e.a, e.b, result, flags, illegal, e.res, e.flg, e.ill);
        end
        cov_sample_flags(e.op, e.sew, flags);
      end
    end

    // (3) accept / reset handling
    if (!rst_n) begin
      if (exp_q.size() != 0 || m_s1) cov_pipe[4] = 1;
      if (stall) cov_pipe[6] = 1;
      if (exp_q.size() != 0) n_reset++;
      exp_q.delete();
      acc_run = 0; prev_accept = 0; have_prev_op = 0;
    end else if (in_valid && !stall) begin
      ref_model(op, sew, a, b, r, f, il);
      e.res = r; e.flg = f; e.ill = il; e.op = op; e.sew = sew; e.a = a; e.b = b; e.t = cyc;
      exp_q.push_back(e);
      n_accept++;
      cov_sample_txn(op, sew, a, b);
      if (have_prev_op && prev_accept) cov_trans[(prev_op > 18) ? 19 : int'(prev_op)][(op > 18) ? 19 : int'(op)] = 1;
      if (gap_after_accept) cov_pipe[3] = 1;
      prev_op = op; have_prev_op = 1;
      acc_run++;  if (acc_run >= 8) cov_pipe[2] = 1;
      prev_accept = 1; gap_after_accept = 0;
    end else begin
      if (prev_accept) gap_after_accept = 1;
      acc_run = 0; prev_accept = 0;
      if (!in_valid) n_bubble++;
    end

    // (4) pipeline-scenario coverage
    if (rst_n) begin
      if (stall && out_valid) cov_pipe[0] = 1;
      if (stall && in_valid)  begin cov_pipe[1] = 1; n_stalled_offer++; end
      if (stall) hold_run++; else begin
        if (prev_stall && hold_run >= 3) cov_pipe[5] = 1;
        if (prev_stall && out_valid) cov_pipe[7] = 1;
        hold_run = 0;
      end
    end
    prev_stall = stall;

    // (5) update the occupancy model for the next cycle
    if (!rst_n)       begin m_s1 = 0; m_out = 0; end
    else if (!stall)  begin m_out = m_s1; m_s1 = in_valid; end
  end

  // ------------------------------ stimulus ------------------------------
  int unsigned cycles_per_phase = 6000;
  int          force_bias = -1;
  int          rst_left = 0;
  string       phase_name = "";

  task automatic run_phase(input string name, input int n, input int opmode, input int sew_mode,
                           input int bias, input int bubble_pct, input int stall_pct, input int rst_permille);
    int bp;
    phase_name = name;
    bp = (force_bias >= 0) ? force_bias : bias;
    for (int k = 0; k < n; k++) begin
      logic [4:0] o; logic [1:0] s; logic [63:0] x, y;
      @(negedge clk);   // drive away from the active edge: no races
      // reset injection (1..3 cycles)
      if (rst_left > 0) begin rst_n = 0; rst_left--; end
      else if (rst_permille > 0 && rnd(1000) < rst_permille) begin rst_n = 0; rst_left = rnd(3); end
      else rst_n = 1;
      stall = (rnd(100) < stall_pct);
      o = gen_op(opmode, k);
      case (sew_mode)
        0: s = 2'(rnd(4));
        1: s = 2'((k / 4) % 4);       // slow sweep
        2: s = 2'((k % 4));           // switch width every cycle
        default: s = 2'(sew_mode - 3);// fixed width
      endcase
      if (opmode == OPM_SWEEP || opmode == OPM_CROSS) s = 2'((k / NUM_OPS) % 4);
      if (opmode == OPM_CROSS) begin                         // exhaustive op x sew x class x class sweep
        x = class_operand((k / (NUM_OPS*4)) % 6, s);
        y = class_operand((k / (NUM_OPS*4*6)) % 6, s);
      end else begin
        x = gen_operand(s, bp, 64'd0);
        y = gen_operand(s, bp, x);
      end
      if (rnd(100) < bubble_pct) begin
        in_valid = 0;
        op = 5'(rnd(32)); sew = 2'(rnd(4)); a = rnd64(); b = rnd64();   // garbage while invalid
      end else begin
        in_valid = 1; op = o; sew = s; a = x; b = y;
      end
    end
  endtask

  initial begin
    longint unsigned seed;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($value$plusargs("cycles=%d", cycles_per_phase));
    if ($test$plusargs("nobias")) force_bias = 0;
    quiet = $test$plusargs("quiet");
    rng_seed(seed);

    repeat (4) @(posedge clk);
    @(negedge clk) rst_n = 1;
    repeat (2) @(posedge clk);

    //          name                 cycles                op mode        sew  bias bub stall rst
    if (force_bias < 0) begin   // +nobias = "pure random" baseline: no directed / corner phases at all
      run_phase("directed_sweep",    NUM_OPS*4*10,         OPM_SWEEP,     0,   80,  0,  0,   0);
      run_phase("class_cross_sweep", NUM_OPS*4*36,         OPM_CROSS,     0,    0,  0,  0,   0);
    end
    run_phase("uniform_mix",         cycles_per_phase,     OPM_ALL,       0,   25,  0,  0,   0);
    run_phase("corner_heavy",        cycles_per_phase,     OPM_ALL,       0,   85,  0,  0,   0);
    run_phase("saturation_focus",    cycles_per_phase,     OPM_SAT,       0,   70,  0,  0,   0);
    run_phase("shift_focus",         cycles_per_phase,     OPM_SHIFT,     0,   60,  0,  0,   0);
    run_phase("logic_cmp_minmax",    cycles_per_phase,     OPM_LOGIC_CMP, 0,   60,  0,  0,   0);
    run_phase("arith_width_thrash",  cycles_per_phase,     OPM_ARITH,     2,   50,  0,  0,   0);
    run_phase("fixed_8",             cycles_per_phase/2,   OPM_ALL,       3,   50,  0,  0,   0);
    run_phase("fixed_16",            cycles_per_phase/2,   OPM_ALL,       4,   50,  0,  0,   0);
    run_phase("fixed_32",            cycles_per_phase/2,   OPM_ALL,       5,   50,  0,  0,   0);
    run_phase("fixed_64",            cycles_per_phase,     OPM_ALL,       6,   70,  0,  0,   0);
    run_phase("bubbles",             cycles_per_phase,     OPM_ALL,       0,   40, 35,  0,   0);
    run_phase("stalls",              cycles_per_phase,     OPM_ALL,       0,   40, 10, 30,   0);
    run_phase("stall_storm",         cycles_per_phase,     OPM_ARITH,     0,   50,  0, 70,   0);
    run_phase("illegal_opcodes",     cycles_per_phase,     OPM_ILLEGAL,   0,   30, 10, 10,   0);
    run_phase("reset_mid_stream",    cycles_per_phase,     OPM_ALL,       0,   40, 10, 25,  15);
    run_phase("final_random",        cycles_per_phase*2,   OPM_ALL,       0,   45, 15, 15,   5);

    // drain
    for (int i = 0; i < 6; i++) begin
      @(negedge clk); in_valid = 0; stall = 0; rst_n = 1;
    end
    repeat (4) @(posedge clk);

    if (exp_q.size() != 0) begin
      sb_err++;
      $display("[SB] %0d expected transactions never emerged from the DUT", exp_q.size());
    end

    $display("------------------------------------------------------------");
    $display("SIMD_ALU regression  seed=%0d  cycles=%0d", seed, cyc);
    $display("  transactions accepted  : %0d", n_accept);
    $display("  outputs checked        : %0d", n_check);
    $display("  offered during stall   : %0d   (must be ignored)", n_stalled_offer);
    $display("  in-flight dropped @rst : %0d", n_reset);
    $display("  scoreboard errors      : %0d  (data %0d, flags %0d, illegal %0d, valid-timing %0d, spurious %0d)",
             sb_err, data_err, flag_err, ill_err, valid_err, spurious);
    $display("  SVA failures           : %0d", sva_fail_total);
    foreach (sva_by_name[n]) $display("      %-28s %0d", n, sva_by_name[n]);
    cov_report();
    if (sb_err == 0 && sva_fail_total == 0 && n_check > 0) $display("RESULT: PASS");
    else                                                   $display("RESULT: FAIL");
    $finish;
  end
endmodule
