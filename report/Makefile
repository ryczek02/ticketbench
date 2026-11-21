# make            build sprawozdanie.pdf, podsumowanie.pdf and prezentacja.pdf (tectonic or latexmk)
# make data RUN=../infra/results/full   refresh generated/ from a result directory
RUN ?= data/results
TEX := $(shell command -v tectonic >/dev/null && echo tectonic || echo latexmk)

.PHONY: all data clean

all: sprawozdanie.pdf podsumowanie.pdf prezentacja.pdf

%.pdf: %.tex sekcje/*.tex generated/macros.tex
ifeq ($(TEX),tectonic)
	tectonic -X compile $<
else
	latexmk -xelatex -interaction=nonstopmode -halt-on-error $<
endif

data:
	rm -rf generated
	tbench report $(RUN) --out generated
	@if [ "$(RUN)" != "data/results" ]; then rm -rf data/results && mkdir -p data && cp -R $(RUN) data/results; fi

clean:
	rm -f *.aux *.log *.out *.toc *.fdb_latexmk *.fls *.xdv
