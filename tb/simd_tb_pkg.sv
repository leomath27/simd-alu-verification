// Testbench support package: PRNG, golden reference model, operand/opcode
// generators, functional-coverage database and assertion-failure bookkeeping.
package simd_tb_pkg;
  import simd_defs_pkg::*;

  // ------------------------------------------------------------------
  // Deterministic, simulator-independent PRNG (xorshift64*) -> reproducible seeds
  // ------------------------------------------------------------------
  longint unsigned rng_state = 64'h9E3779B97F4A7C15;

  function automatic void rng_seed(longint unsigned s);
    rng_state = (s * 64'hD1B54A32D192ED03) ^ 64'h9E3779B97F4A7C15;
    if (rng_state == 0) rng_state = 64'h1;
    repeat (8) void'(rnd64());
  endfunction

  function automatic logic [63:0] rnd64();
    rng_state ^= rng_state >> 12;
    rng_state ^= rng_state << 25;
    rng_state ^= rng_state >> 27;
    return rng_state * 64'h2545F4914F6CDD1D;
  endfunction

  function automatic int unsigned rnd(input int unsigned n);   // uniform in [0,n)
    logic [63:0] v;
    v = rnd64();
    return int'(v[63:32] % n);
  endfunction

  // ------------------------------------------------------------------
  // Golden reference model: written independently of the RTL, using wide
  // (128-bit) signed integer arithmetic per lane instead of bit tricks.
  // ------------------------------------------------------------------
  function automatic logic signed [127:0] lane_sx(input logic signed [127:0] u, input int w);
    logic signed [127:0] half;
    half = 128'sd1 <<< (w - 1);
    return (u ^ half) - half;          // sign-extend a w-bit value
  endfunction

  function automatic void ref_model(input  logic [4:0]  op,  input logic [1:0] sew,
                                    input  logic [63:0] a,   input logic [63:0] b,
                                    output logic [63:0] res, output logic [7:0] flg,
                                    output logic        ill);
    int W, N;
    logic signed [127:0] m, smax, smin, ua, ub, sa, sb, t, r;
    logic f;
    W = 8 << sew;  N = 64 / W;
    m    = (128'sd1 <<< W) - 128'sd1;
    smax = (128'sd1 <<< (W - 1)) - 128'sd1;
    smin = -(128'sd1 <<< (W - 1));
    res = '0; flg = '0; ill = 1'b0;
    if (op > 5'd18) begin
      ill = 1'b1;
    end else begin
      for (int i = 0; i < N; i++) begin
        ua = {64'b0, a >> (i * W)} & m;
        ub = {64'b0, b >> (i * W)} & m;
        sa = lane_sx(ua, W);
        sb = lane_sx(ub, W);
        r = 0; f = 1'b0;
        case (op)
          OP_ADD:  begin t = sa + sb; f = (t > smax) || (t < smin); r = t; end
          OP_SUB:  begin t = sa - sb; f = (t > smax) || (t < smin); r = t; end
          OP_ADDS: begin t = sa + sb; f = (t > smax) || (t < smin); r = (t > smax) ? smax : (t < smin) ? smin : t; end
          OP_SUBS: begin t = sa - sb; f = (t > smax) || (t < smin); r = (t > smax) ? smax : (t < smin) ? smin : t; end
          OP_ADDU: begin t = ua + ub; f = (t > m); r = (t > m) ? m : t; end
          OP_SUBU: begin t = ua - ub; f = (t < 0); r = (t < 0) ? 128'sd0 : t; end
          OP_AND:  r = ua & ub;
          OP_OR:   r = ua | ub;
          OP_XOR:  r = ua ^ ub;
          OP_MINS: r = (sa < sb) ? sa : sb;
          OP_MAXS: r = (sa > sb) ? sa : sb;
          OP_MINU: r = (ua < ub) ? ua : ub;
          OP_MAXU: r = (ua > ub) ? ua : ub;
          OP_SHL:  r = ua <<< int'(ub % W);
          OP_SHR:  r = ua >>> int'(ub % W);
          OP_SAR:  r = sa >>> int'(ub % W);
          OP_CMPEQ: r = (ua == ub) ? m : 128'sd0;
          OP_CMPGT: r = (sa > sb)  ? m : 128'sd0;
          OP_ABSDU: r = (ua > ub) ? (ua - ub) : (ub - ua);
          default: ;
        endcase
        r = r & m;
        res = res | (64'(r) << (i * W));
        flg[i] = f;
      end
    end
  endfunction

  // ------------------------------------------------------------------
  // Stimulus generation
  // ------------------------------------------------------------------
  typedef enum int {OPM_ALL, OPM_ARITH, OPM_SAT, OPM_SHIFT, OPM_LOGIC_CMP, OPM_ILLEGAL, OPM_SWEEP, OPM_CROSS} opmode_e;

  function automatic logic [63:0] lane_mask(input int w);
    return (w == 64) ? 64'hFFFF_FFFF_FFFF_FFFF : ((64'd1 << w) - 64'd1);
  endfunction

  // Build an operand lane by lane. With probability bias_pct a lane takes a
  // "corner" value (0, -1, MIN, MAX, MIN+1, MAX-1, 1, W-1, W, or a value
  // derived from the other operand's lane); otherwise it is uniform random.
  function automatic logic [63:0] gen_operand(input int sew, input int bias_pct, input logic [63:0] other);
    int W, N;
    logic [63:0] v, lane, mk, ol, mn, mx;
    W = 8 << sew;  N = 64 / W;
    mk = lane_mask(W);
    mn = 64'd1 << (W - 1);
    mx = mn - 64'd1;
    v  = '0;
    for (int i = 0; i < N; i++) begin
      ol = (other >> (i * W)) & mk;
      if (rnd(100) < bias_pct) begin
        case (rnd(13))
          0:  lane = 64'd0;
          1:  lane = mk;
          2:  lane = mn;
          3:  lane = mx;
          4:  lane = 64'd1;
          5:  lane = (mn + 64'd1) & mk;
          6:  lane = (mx - 64'd1) & mk;
          7:  lane = ol;                       // equal operands (CMPEQ / ABSD / SUB-to-zero)
          8:  lane = (~ol) & mk;               // a + ~a = all-ones (carry-chain corner)
          9:  lane = (64'd0 - ol) & mk;        // a + (-a) = 0
          10: lane = W - 1;                    // largest legal shift amount
          11: lane = W;                        // shift amount == width (must wrap)
          default: lane = (ol + 64'd1) & mk;
        endcase
      end else begin
        lane = rnd64() & mk;
      end
      v = v | (lane << (i * W));
    end
    return v;
  endfunction

  // Directed value for a coverage class, replicated into every lane
  function automatic logic [63:0] class_operand(input int cls, input int sew);
    int W, N;
    logic [63:0] mk, mn, lane, v;
    W = 8 << sew;  N = 64 / W;
    mk = lane_mask(W);  mn = 64'd1 << (W - 1);
    case (cls)
      0: lane = 64'd0;
      1: lane = mk;
      2: lane = mn;
      3: lane = mn - 64'd1;
      4: lane = 64'd1;
      default: lane = (rnd64() & mk);
    endcase
    v = '0;
    for (int i = 0; i < N; i++) v = v | (lane << (i * W));
    return v;
  endfunction

  function automatic logic [4:0] gen_op(input int mode, input int k);
    case (mode)
      OPM_ARITH:     return 5'(rnd(6));
      OPM_SAT:       return 5'(2 + rnd(4));
      OPM_SHIFT:     return 5'(13 + rnd(3));
      OPM_LOGIC_CMP: begin
        case (rnd(7)) 0: return OP_AND; 1: return OP_OR; 2: return OP_XOR;
                      3: return 5'(9 + rnd(4)); 4: return OP_CMPEQ; 5: return OP_CMPGT; default: return OP_ABSDU;
        endcase
      end
      OPM_ILLEGAL:   return (rnd(2) == 0) ? 5'(19 + rnd(13)) : 5'(rnd(19));
      OPM_SWEEP, OPM_CROSS: return 5'(k % NUM_OPS);
      default:       return (rnd(100) < 4) ? 5'(19 + rnd(13)) : 5'(rnd(NUM_OPS));
    endcase
  endfunction

  // ------------------------------------------------------------------
  // Functional coverage database (hand-rolled bins: Verilator has no covergroup)
  // ------------------------------------------------------------------
  localparam int NOPB = NUM_OPS + 1;      // 19 legal opcodes + 1 bin for "any illegal"
  localparam int NCLS = 6;                // ZERO, ONES(-1), MIN, MAX, ONE, OTHER

  bit cov_opsew  [NOPB][4];               // opcode x element width
  bit cov_cls    [NUM_OPS][4][NCLS][NCLS];// opcode x sew x class(a lane) x class(b lane)
  bit cov_trans  [NOPB][NOPB];            // back-to-back opcode transitions
  bit cov_flag   [6][4];                  // flag asserted: ADD..SUBU x sew
  bit cov_noflag [6][4];                  // flag NOT asserted for the same
  bit cov_pipe   [8];
  string pipe_names [8] = '{"stall_with_output_valid", "stall_while_input_offered", "back_to_back_8_accepts",
                            "bubble_between_accepts", "reset_with_inflight", "stall_hold_3plus_cycles",
                            "reset_during_stall", "stall_release_with_valid"};

  function automatic int lane_class(input logic [63:0] v, input int w);
    logic [63:0] mk, mn;
    mk = lane_mask(w);  mn = 64'd1 << (w - 1);
    v = v & mk;
    if (v == 0)       return 0;
    if (v == mk)      return 1;
    if (v == mn)      return 2;
    if (v == mn - 1)  return 3;
    if (v == 1)       return 4;
    return 5;
  endfunction

  function automatic void cov_sample_txn(input logic [4:0] op, input logic [1:0] sew,
                                         input logic [63:0] a, input logic [63:0] b);
    int W, N;
    W = 8 << sew; N = 64 / W;
    cov_opsew[(op > 18) ? 19 : int'(op)][sew] = 1'b1;
    if (op <= 18)
      for (int i = 0; i < N; i++)
        cov_cls[op][sew][lane_class(a >> (i*W), W)][lane_class(b >> (i*W), W)] = 1'b1;
  endfunction

  function automatic void cov_sample_flags(input logic [4:0] op, input logic [1:0] sew, input logic [7:0] flg);
    int N;
    N = 64 / (8 << sew);
    if (op <= 5)
      for (int i = 0; i < N; i++) begin
        if (flg[i]) cov_flag[op][sew] = 1'b1; else cov_noflag[op][sew] = 1'b1;
      end
  endfunction

  function automatic void cov_report();
    int hit, tot, h, t;
    int hole_print;
    string nm;
    hit = 0; tot = 0;
    h = 0; t = 0;
    for (int o = 0; o < NOPB; o++) for (int s = 0; s < 4; s++) begin t++; if (cov_opsew[o][s]) h++; end
    $display("COV  opcode x element-width            : %4d / %4d bins  (%5.1f%%)", h, t, 100.0*h/t);
    hit += h; tot += t;
    h = 0; t = 0;
    for (int o = 0; o < NUM_OPS; o++) for (int s = 0; s < 4; s++)
      for (int x = 0; x < NCLS; x++) for (int y = 0; y < NCLS; y++) begin t++; if (cov_cls[o][s][x][y]) h++; end
    $display("COV  opcode x sew x class(a) x class(b): %4d / %4d bins  (%5.1f%%)", h, t, 100.0*h/t);
    hit += h; tot += t;
    h = 0; t = 0;
    for (int o = 0; o < NOPB; o++) for (int p = 0; p < NOPB; p++) begin t++; if (cov_trans[o][p]) h++; end
    $display("COV  back-to-back opcode transitions   : %4d / %4d bins  (%5.1f%%)", h, t, 100.0*h/t);
    hit += h; tot += t;
    h = 0; t = 0;
    for (int o = 0; o < 6; o++) for (int s = 0; s < 4; s++) begin
      t += 2; if (cov_flag[o][s]) h++; if (cov_noflag[o][s]) h++;
    end
    $display("COV  overflow/saturation flag set/clear: %4d / %4d bins  (%5.1f%%)", h, t, 100.0*h/t);
    hit += h; tot += t;
    h = 0; t = 8;
    for (int p = 0; p < 8; p++) if (cov_pipe[p]) h++; else $display("COV    hole: pipeline scenario '%s'", pipe_names[p]);
    $display("COV  pipeline / protocol scenarios     : %4d / %4d bins  (%5.1f%%)", h, t, 100.0*h/t);
    hit += h; tot += t;
    $display("COV  TOTAL functional coverage         : %4d / %4d bins  (%5.1f%%)", hit, tot, 100.0*hit/tot);
    hole_print = 0;
    for (int o = 0; o < NUM_OPS; o++) for (int s = 0; s < 4; s++)
      for (int x = 0; x < NCLS; x++) for (int y = 0; y < NCLS; y++)
        if (!cov_cls[o][s][x][y] && hole_print < 5) begin
          hole_print++;
          $display("COV    hole: op=%0d sew=%0d class(a)=%0d class(b)=%0d", o, s, x, y);
        end
  endfunction

  // ------------------------------------------------------------------
  // Assertion-failure bookkeeping (SVA action blocks call sva_fail)
  // ------------------------------------------------------------------
  int sva_fail_total = 0;
  int sva_by_name [string];

  function automatic void sva_fail(input string name);
    sva_fail_total++;
    if (!sva_by_name.exists(name)) begin
      sva_by_name[name] = 0;
      $display("[SVA FAIL] %s first failed @ %0t", name, $time);
    end
    sva_by_name[name]++;
  endfunction
endpackage
