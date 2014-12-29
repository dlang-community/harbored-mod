.PHONY: all clean doc

SRC:=src/*.d\
	libddoc/src/ddoc/*.d\
	libdparse/src/std/*.d\
	libdparse/src/std/d/*.d\
	dmarkdown/source/dmarkdown/*.d

IMPORTS:=-Ilibdparse/src\
	-Ilibddoc/src\
	-Idmarkdown/source\
	-Jstrings

FLAGS:=-O -inline

all: $(SRC)
	dmd $(SRC) $(IMPORTS) $(FLAGS) -ofbin/hmod
	rm -f bin/*.o

clean:
	rm -rf bin/

doc:
	./bin/hmod src/
