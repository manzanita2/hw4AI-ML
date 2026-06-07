# Build the M4 design justification PDF.
#   make         -> design_justification.pdf (pdflatex run twice for refs)
#   make clean   -> remove LaTeX aux files (keeps the PDF)
#   make cleanall-> also remove the PDF
#
# Requires: pdflatex (TeX Live). Figures are pulled from ../bench and ../sim
# plus figures/ (drop figures/psu_logo.png for the title page).

TEX     := design_justification
LATEX   := pdflatex
# nonstopmode keeps the build going past benign font-substitution notices on
# minimal TeX installs (a complete TeX Live emits none of them).
LFLAGS  := -interaction=nonstopmode

.PHONY: all clean cleanall

all: $(TEX).pdf

$(TEX).pdf: $(TEX).tex
	-$(LATEX) $(LFLAGS) $(TEX).tex
	$(LATEX) $(LFLAGS) $(TEX).tex

clean:
	rm -f $(TEX).aux $(TEX).log $(TEX).out $(TEX).toc

cleanall: clean
	rm -f $(TEX).pdf
