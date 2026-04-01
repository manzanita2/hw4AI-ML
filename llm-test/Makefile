SRCDIR:="."
OUTDIR:="./bin"

TB_SRCS := ${SRCDIR}/adder4.v ${SRCDIR}/tb_adder4.v
TB_OUT  := ${OUTDIR}/tb_adder4.out

all: sim

${OUTDIR}:
	mkdir -p ${OUTDIR}

build: ${OUTDIR}
	iverilog -g2005-sv ${TB_SRCS} -o ${TB_OUT}

sim: build
	vvp ${TB_OUT}

clean:
	rm -rf ${OUTDIR}

.PHONY: all build sim clean

