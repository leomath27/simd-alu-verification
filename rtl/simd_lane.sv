// One SIMD lane of width W. ADD/SUB data comes from the shared segmented
// (SWAR) adder in simd_alu; everything else is computed per lane here.
module simd_lane import simd_defs_pkg::*; #(parameter int W = 8) (
  input  logic [4:0]   op,
  input  logic [W-1:0] a, b,
  input  logic [W-1:0] add_r, sub_r,   // lane slices of the segmented adder/subtractor
  output logic [W-1:0] r,
  output logic         flag            // overflow (ADD/SUB) or saturation (ADDS/ADDU/SUBS/SUBU)
);
  localparam int SHW = $clog2(W);
  localparam logic [W-1:0] MIN_S = {1'b1, {(W-1){1'b0}}};
  localparam logic [W-1:0] MAX_S = {1'b0, {(W-1){1'b1}}};

  logic add_ovf, sub_ovf;
  logic [W:0]   usum;
  logic [SHW-1:0] sh;

  always_comb begin
    add_ovf = (a[W-1] == b[W-1]) && (add_r[W-1] != a[W-1]);
    sub_ovf = (a[W-1] != b[W-1]) && (sub_r[W-1] != a[W-1]);
    usum    = {1'b0, a} + {1'b0, b};
    sh      = b[SHW-1:0];
    r       = '0;
    flag    = 1'b0;
    case (op)
      OP_ADD: begin
        r = add_r;
`ifdef BUG_OVF64
        flag = (W == 64) ? 1'b0 : add_ovf;
`else
        flag = add_ovf;
`endif
      end
      OP_SUB:  begin r = sub_r; flag = sub_ovf; end
      OP_ADDS: begin
        flag = add_ovf;
        r    = add_ovf ? (a[W-1] ? MIN_S : MAX_S) : add_r;
`ifdef BUG_CORNER
        if (W == 64 && a == MIN_S && b == MIN_S) r = '0;   // rare corner: -2^63 + -2^63
`endif
      end
      OP_ADDU: begin
        flag = usum[W];
`ifdef BUG_ADDU_SAT
        r    = usum[W] ? ((W == 16) ? MAX_S : {W{1'b1}}) : usum[W-1:0];
`else
        r    = usum[W] ? {W{1'b1}} : usum[W-1:0];
`endif
      end
      OP_SUBS: begin
        flag = sub_ovf;
        r    = sub_ovf ? (a[W-1] ? MIN_S : MAX_S) : sub_r;
      end
      OP_SUBU: begin flag = (a < b); r = (a < b) ? '0 : (a - b); end
      OP_AND:  r = a & b;
      OP_OR:   r = a | b;
      OP_XOR:  r = a ^ b;
      OP_MINS: begin
`ifdef BUG_MINS8
        if (W == 8) r = (a < b) ? a : b; else
`endif
        r = ($signed(a) < $signed(b)) ? a : b;
      end
      OP_MAXS: r = ($signed(a) > $signed(b)) ? a : b;
      OP_MINU: r = (a < b) ? a : b;
      OP_MAXU: r = (a > b) ? a : b;
      OP_SHL: begin
`ifdef BUG_SHAMT8
        if (W == 8) r = a << b[3:0]; else
`endif
        r = a << sh;
      end
      OP_SHR:  r = a >> sh;
      OP_SAR: begin
`ifdef BUG_SAR32
        if (W == 32) r = a >> sh; else
`endif
        r = $signed(a) >>> sh;
      end
      OP_CMPEQ: r = (a == b) ? {W{1'b1}} : '0;
      OP_CMPGT: begin
`ifdef BUG_CMPGT16
        if (W == 16) r = ($signed(a) > $signed(b)) ? W'(1) : '0; else
`endif
        r = ($signed(a) > $signed(b)) ? {W{1'b1}} : '0;
      end
      OP_ABSDU: begin
`ifdef BUG_ABSD_SGN
        if (W == 8) r = ($signed(a) > $signed(b)) ? (a - b) : (b - a); else
`endif
        r = (a > b) ? (a - b) : (b - a);
      end
      default: begin
`ifdef BUG_ILLEGAL
        if (op == 5'd19) r = add_r;
`endif
      end
    endcase
  end
endmodule
