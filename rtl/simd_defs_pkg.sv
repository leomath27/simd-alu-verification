// Shared opcode / element-width encodings for the SIMD ALU.
package simd_defs_pkg;
  localparam logic [4:0] OP_ADD   = 5'd0,  OP_SUB   = 5'd1,  // modular (wrap-around)
                         OP_ADDS  = 5'd2,  OP_ADDU  = 5'd3,  // saturating add  (signed / unsigned)
                         OP_SUBS  = 5'd4,  OP_SUBU  = 5'd5,  // saturating sub  (signed / unsigned)
                         OP_AND   = 5'd6,  OP_OR    = 5'd7,  OP_XOR = 5'd8,
                         OP_MINS  = 5'd9,  OP_MAXS  = 5'd10, OP_MINU = 5'd11, OP_MAXU = 5'd12,
                         OP_SHL   = 5'd13, OP_SHR   = 5'd14, OP_SAR  = 5'd15,
                         OP_CMPEQ = 5'd16, OP_CMPGT = 5'd17, // lane mask: all-ones if true
                         OP_ABSDU = 5'd18;                   // |a-b| unsigned
  localparam int NUM_OPS = 19;                               // opcodes 19..31 are illegal
  localparam logic [1:0] SEW8 = 2'd0, SEW16 = 2'd1, SEW32 = 2'd2, SEW64 = 2'd3;
endpackage
