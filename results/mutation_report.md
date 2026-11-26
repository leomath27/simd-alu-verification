| # | Injected bug | Caught (corner-biased) | Caught (pure random) | First SVA that fired |
|---|---|---|---|---|
| 1 | segmented adder: 16-bit lane mask wrong (carry crosses lanes) | scoreboard+SVA | scoreboard+SVA | A_LANE_ADD_MODULAR, A_LANE_SUB_MODULAR |
| 2 | ADDU 16-bit saturates to 0x7FFF instead of 0xFFFF | scoreboard+SVA | scoreboard+SVA | A_LANE_ADDU_MONOTONE |
| 3 | SAR on 32-bit lanes is logical, not arithmetic | scoreboard+SVA | scoreboard+SVA | A_LANE_SAR_SIGN |
| 4 | MINS on 8-bit lanes uses unsigned compare | scoreboard+SVA | scoreboard+SVA | A_LANE_MINS |
| 5 | ABSDU on 8-bit lanes uses signed compare | scoreboard+SVA | scoreboard+SVA | A_LANE_ABSD |
| 6 | CMPGT on 16-bit lanes returns 1 instead of all-ones mask | scoreboard+SVA | scoreboard+SVA | A_LANE_CMP_MASK, A_LANE_CMPGT |
| 7 | 8-bit shift amount not wrapped mod 8 (uses b[3:0]) | scoreboard+SVA | scoreboard+SVA | A_LANE_SHIFT0 |
| 8 | ADD overflow flag missing for 64-bit lane | scoreboard+SVA | scoreboard+SVA | A_LANE_ADD_OVF_FLAG |
| 9 | opcode 19 executes as ADD, illegal flag not raised | scoreboard+SVA | scoreboard+SVA | A_ILLEGAL_DECODE |
| 10 | result register keeps updating while stalled | scoreboard+SVA | scoreboard+SVA | A_STALL_HOLDS_OUT |
| 11 | pipeline accepts an instruction while stalled | scoreboard+SVA | scoreboard+SVA | A_STALL_HOLDS_S1 |
| 12 | reset does not clear stage-1 valid (stale instruction survives reset) | scoreboard+SVA | scoreboard+SVA | A_RESET_CLEARS_VALID |
| 13 | 64-bit ADDS of MIN+MIN wraps to 0 instead of saturating (rare corner) | scoreboard+SVA | MISSED | A_LANE_SAT_RAIL |

**13/13 mutants caught with the corner-biased generator; 12/13 with pure uniform-random operands.** Clean RTL passes.
