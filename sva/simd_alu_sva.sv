// Assertion suite for simd_alu, attached with `bind` (no RTL edits needed).
//   * pipeline/protocol properties on ports and stage-1 registers
//   * lane-level algebraic invariants (generated for every lane of every element
//     width) that check the execute stage independently of the scoreboard model
//
// Failures call simd_tb_pkg::sva_fail() so the testbench can count them per name.
`define A(NAME, PROP) \
  NAME: assert property (@(posedge clk) disable iff (!rst_n) PROP) \
        else simd_tb_pkg::sva_fail(`"NAME`");

module simd_alu_sva import simd_defs_pkg::*; (
  input logic        clk, rst_n,
  input logic        in_valid, stall,
  input logic [4:0]  op,
  input logic [1:0]  sew,
  input logic [63:0] a, b,
  input logic        out_valid,
  input logic [63:0] result,
  input logic [7:0]  flags,
  input logic        illegal,
  // internal probes
  input logic        s1_valid,
  input logic [4:0]  s1_op,
  input logic [1:0]  s1_sew,
  input logic [63:0] s1_a, s1_b,
  input logic [63:0] res_c,
  input logic [7:0]  flg_c,
  input logic        ill_c
);
  // ---------------- reset ----------------
  A_RESET_CLEARS_VALID: assert property (@(posedge clk) !rst_n |=> !out_valid && !s1_valid)
    else simd_tb_pkg::sva_fail("A_RESET_CLEARS_VALID");

  // ---------------- pipeline / handshake ----------------
  `A(A_ACCEPT_LOADS_S1,   (in_valid && !stall) |=> s1_valid && (s1_op == $past(op)) && (s1_sew == $past(sew))
                                                  && (s1_a == $past(a)) && (s1_b == $past(b)))
  `A(A_BUBBLE_STAYS_BUBBLE, (!in_valid && !stall) |=> !s1_valid)
  `A(A_ADVANCE_VALID,     !stall |=> (out_valid == $past(s1_valid)))
  `A(A_LATENCY_2,         ($past(in_valid && !stall && rst_n, 2) && $past(!stall && rst_n, 1)) |-> out_valid)
  `A(A_STALL_HOLDS_S1,    stall |=> $stable({s1_valid, s1_op, s1_sew, s1_a, s1_b}))
  `A(A_STALL_HOLDS_OUT,   stall |=> $stable({out_valid, result, flags, illegal}))

  // ---------------- decode / flags ----------------
  `A(A_ILLEGAL_DECODE,    s1_valid |-> (ill_c == (s1_op > 5'd18)))
  `A(A_ILLEGAL_RESULT_ZERO, ill_c |-> (res_c == 64'd0 && flg_c == 8'd0))
  `A(A_FLAGS_ONLY_ON_ADDSUB, (s1_valid && s1_op >= OP_AND) |-> flg_c == 8'd0)
  `A(A_FLAGS_UPPER_16,    (s1_valid && s1_sew == SEW16) |-> flg_c[7:4] == 4'd0)
  `A(A_FLAGS_UPPER_32,    (s1_valid && s1_sew == SEW32) |-> flg_c[7:2] == 6'd0)
  `A(A_FLAGS_UPPER_64,    (s1_valid && s1_sew == SEW64) |-> flg_c[7:1] == 7'd0)

  // ---------------- lane-level invariants ----------------
  for (genvar w = 0; w < 4; w++) begin : g_sew
    localparam int W = 8 << w;
    localparam int N = 64 / W;
    localparam int SHW = $clog2(W);
    wire v = s1_valid && (s1_sew == 2'(w)) && !ill_c;

    for (genvar i = 0; i < N; i++) begin : g_lane
      wire [W-1:0] la = s1_a[i*W +: W];
      wire [W-1:0] lb = s1_b[i*W +: W];
      wire [W-1:0] lr = res_c[i*W +: W];
      wire [W:0]   us = {1'b0, la} + {1'b0, lb};
      wire         lf = flg_c[i];
      localparam logic [W-1:0] MINS = {1'b1, {(W-1){1'b0}}};
      localparam logic [W-1:0] MAXS = {1'b0, {(W-1){1'b1}}};

      // modular add/sub must not leak carries/borrows across lane boundaries
      `A(A_LANE_ADD_MODULAR, (v && s1_op == OP_ADD) |-> lr == (la + lb))
      `A(A_LANE_SUB_MODULAR, (v && s1_op == OP_SUB) |-> lr == (la - lb))
      // overflow flags (signed): operands same sign & result sign flips (add); opposite sign (sub)
      `A(A_LANE_ADD_OVF_FLAG, (v && (s1_op == OP_ADD || s1_op == OP_ADDS)) |->
            (lf == ((la[W-1] == lb[W-1]) && ((la + lb) >> (W-1)) != {{(W-1){1'b0}}, la[W-1]})))
      `A(A_LANE_SUB_OVF_FLAG, (v && (s1_op == OP_SUB || s1_op == OP_SUBS)) |->
            (lf == ((la[W-1] != lb[W-1]) && ((la - lb) >> (W-1)) != {{(W-1){1'b0}}, la[W-1]})))
      // unsigned saturation
      `A(A_LANE_ADDU_MONOTONE, (v && s1_op == OP_ADDU) |-> (lr >= la) && (lr >= lb) && (lr == {W{1'b1}} || lr == (la + lb)))
      `A(A_LANE_ADDU_FLAG,     (v && s1_op == OP_ADDU) |-> (lf == us[W]))
      `A(A_LANE_SUBU_BOUND,    (v && s1_op == OP_SUBU) |-> (lr <= la) && (lf == (la < lb)))
      // signed saturation lands on a rail iff flagged
      `A(A_LANE_SAT_RAIL,      (v && (s1_op == OP_ADDS || s1_op == OP_SUBS) && lf) |-> (lr == MINS || lr == MAXS))
      `A(A_LANE_SAT_NOFLAG_EXACT, (v && s1_op == OP_ADDS && !lf) |-> lr == (la + lb))
      // logic
      `A(A_LANE_LOGIC,   v |-> ((s1_op != OP_AND) || lr == (la & lb)) && ((s1_op != OP_OR) || lr == (la | lb)) && ((s1_op != OP_XOR) || lr == (la ^ lb)))
      // min / max
      `A(A_LANE_MINU,    (v && s1_op == OP_MINU) |-> (lr <= la) && (lr <= lb) && (lr == la || lr == lb))
      `A(A_LANE_MAXU,    (v && s1_op == OP_MAXU) |-> (lr >= la) && (lr >= lb) && (lr == la || lr == lb))
      `A(A_LANE_MINS,    (v && s1_op == OP_MINS) |-> ($signed(lr) <= $signed(la)) && ($signed(lr) <= $signed(lb)) && (lr == la || lr == lb))
      `A(A_LANE_MAXS,    (v && s1_op == OP_MAXS) |-> ($signed(lr) >= $signed(la)) && ($signed(lr) >= $signed(lb)) && (lr == la || lr == lb))
      // compares produce full-lane masks
      `A(A_LANE_CMP_MASK, (v && (s1_op == OP_CMPEQ || s1_op == OP_CMPGT)) |-> (lr == '0 || lr == {W{1'b1}}))
      `A(A_LANE_CMPEQ,    (v && s1_op == OP_CMPEQ) |-> ((lr == {W{1'b1}}) == (la == lb)))
      `A(A_LANE_CMPGT,    (v && s1_op == OP_CMPGT) |-> ((lr == {W{1'b1}}) == ($signed(la) > $signed(lb))))
      // shifts: amount is taken modulo the element width
      `A(A_LANE_SHIFT0,   (v && (s1_op == OP_SHL || s1_op == OP_SHR || s1_op == OP_SAR) && lb[SHW-1:0] == '0) |-> lr == la)
      `A(A_LANE_SHR_LE,   (v && s1_op == OP_SHR) |-> lr <= la)
      `A(A_LANE_SAR_SIGN, (v && s1_op == OP_SAR) |-> lr[W-1] == la[W-1])
      `A(A_LANE_SHL_SHAMT_MOD, (v && s1_op == OP_SHL && lb[SHW-1:0] == SHW'(1) && W > 8) |-> lr == {la[W-2:0], 1'b0})
      // |a-b|
      `A(A_LANE_ABSD,     (v && s1_op == OP_ABSDU) |-> lr == ((la > lb) ? (la - lb) : (lb - la)))
    end
  end
endmodule

// Attach to every simd_alu instance
bind simd_alu simd_alu_sva u_sva (.*);
