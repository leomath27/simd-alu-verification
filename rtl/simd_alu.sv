// 64-bit SIMD ALU, 2-stage pipeline, element width selectable per instruction
// (8x8, 4x16, 2x32, 1x64). Per-lane overflow / saturation flags.
//
//   cycle t   : accepted into stage 1  (in_valid && !stall)
//   cycle t+1 : combinational execute, result registered into stage 2
//   cycle t+2 : out_valid / result / flags visible
//
// `stall` freezes the whole pipe (all registers hold, new inputs ignored).
// Synchronous active-low reset clears both valid bits.
module simd_alu import simd_defs_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        in_valid,
  input  logic        stall,
  input  logic [4:0]  op,
  input  logic [1:0]  sew,
  input  logic [63:0] a,
  input  logic [63:0] b,
  output logic        out_valid,
  output logic [63:0] result,
  output logic [7:0]  flags,
  output logic        illegal
);
  // ---------------- stage 1 registers ----------------
  logic        s1_valid;
  logic [4:0]  s1_op;
  logic [1:0]  s1_sew;
  logic [63:0] s1_a, s1_b;

  // ---------------- execute (combinational) ----------------
  logic [63:0] H, add_r, sub_r, res_c;
  logic [7:0]  flg_c;
  logic        ill_c;

  // Segmented add/sub: H marks the MSB of each lane; carries/borrows are
  // killed at lane boundaries by masking the MSBs out of the carry chain.
  always_comb begin
    case (s1_sew)
      SEW8:    H = {8{8'h80}};
      SEW16:   H = {4{16'h8000}};
      SEW32:   H = {2{32'h8000_0000}};
      default: H = 64'h8000_0000_0000_0000;
    endcase
`ifdef BUG_CARRY16
    if (s1_sew == SEW16) H = {8{8'h80}};
`endif
    add_r = ((s1_a & ~H) + (s1_b & ~H)) ^ ((s1_a ^ s1_b) & H);
    sub_r = ((s1_a |  H) - (s1_b & ~H)) ^ ((s1_a ^ ~s1_b) & H);
  end

  logic [63:0] r_by [4];
  logic [7:0]  f_by [4];

  for (genvar s = 0; s < 4; s++) begin : g_sew
    localparam int W = 8 << s;
    localparam int N = 64 / W;
    logic [63:0] rr;
    logic [N-1:0] fl;
    for (genvar i = 0; i < N; i++) begin : g_lane
      simd_lane #(.W(W)) u_lane (
        .op(s1_op), .a(s1_a[i*W +: W]), .b(s1_b[i*W +: W]),
        .add_r(add_r[i*W +: W]), .sub_r(sub_r[i*W +: W]),
        .r(rr[i*W +: W]), .flag(fl[i]));
    end
    if (N < 8) begin : g_pad
      assign f_by[s] = {{(8-N){1'b0}}, fl};
    end else begin : g_nopad
      assign f_by[s] = fl;
    end
    if (W < 64) begin : g_hi
      assign r_by[s] = rr;
    end else begin : g_full
      assign r_by[s] = rr;
    end
  end

`ifdef BUG_ILLEGAL
  assign ill_c = (s1_op > 5'd18) && (s1_op != 5'd19);
`else
  assign ill_c = (s1_op > 5'd18);
`endif
  assign res_c = ill_c ? 64'd0 : r_by[s1_sew];
  assign flg_c = ill_c ? 8'd0  : f_by[s1_sew];

  // ---------------- sequential ----------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
`ifndef BUG_RST
      s1_valid  <= 1'b0;
`endif
      out_valid <= 1'b0;
    end else if (!stall) begin
      s1_valid  <= in_valid;
      out_valid <= s1_valid;
    end
`ifdef BUG_STALL_ACCEPT
    else if (in_valid && !s1_valid) s1_valid <= 1'b1;   // accepts while frozen
`endif
  end

  always_ff @(posedge clk) begin
    if (!stall) begin
      s1_op <= op; s1_sew <= sew; s1_a <= a; s1_b <= b;
    end
`ifdef BUG_STALL_ACCEPT
    else if (in_valid && !s1_valid) begin s1_op <= op; s1_sew <= sew; s1_a <= a; s1_b <= b; end
`endif
`ifdef BUG_STALL
    result <= res_c; flags <= flg_c; illegal <= ill_c;    // result keeps updating during stall
`else
    if (!stall) begin result <= res_c; flags <= flg_c; illegal <= ill_c; end
`endif
  end
endmodule
