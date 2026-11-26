# SIMD ALU verification  --  needs Verilator >= 5.020, g++, make, python3
VERILATOR ?= verilator
SRC   = rtl/simd_defs_pkg.sv tb/simd_tb_pkg.sv rtl/simd_lane.sv rtl/simd_alu.sv sva/simd_alu_sva.sv tb/tb_top.sv
VFLAGS = --binary --timing --assert -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
         --top-module tb_top -O1
SEED  ?= 1
CYC   ?= 6000

.PHONY: sim regress mutants clean
sim:
	@mkdir -p build
	$(VERILATOR) $(VFLAGS) -Mdir build/sim $(SRC) > build_sim.log 2>&1 || (tail -40 build_sim.log; false)
	./build/sim/Vtb_top +seed=$(SEED) +cycles=$(CYC)

regress:                              ## N seeds on the clean RTL
	python3 scripts/regress.py

mutants:                              ## inject bugs, check each one is caught
	python3 scripts/mutants.py

clean:
	rm -rf build build_*.log
