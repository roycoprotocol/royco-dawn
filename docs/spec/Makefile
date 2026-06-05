# Royco Dusk spec - LaTeX build harness.
#
# Targets:
#   make         build the PDF once
#   make watch   continuous rebuild on file change (uses latexmk -pvc)
#   make clean   remove all build artifacts
#   make open    build then open the PDF in the default viewer
#
# Output: build/main.pdf

MAIN  := main
BUILD := build
PDF   := $(BUILD)/$(MAIN).pdf

LATEXMK_FLAGS := -pdf -outdir=$(BUILD) -interaction=nonstopmode -halt-on-error -file-line-error

.PHONY: pdf watch clean open

pdf: $(PDF)

$(PDF): $(MAIN).tex preamble.tex $(wildcard sections/*.tex)
	@mkdir -p $(BUILD)
	latexmk $(LATEXMK_FLAGS) $(MAIN).tex

watch:
	@mkdir -p $(BUILD)
	latexmk $(LATEXMK_FLAGS) -pvc $(MAIN).tex

clean:
	latexmk -C -outdir=$(BUILD) $(MAIN).tex 2>/dev/null || true
	rm -rf $(BUILD)

open: pdf
	open $(PDF)
