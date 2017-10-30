.PHONY: all clean doc

SRC:=src/*.d\
	libddoc/src/ddoc/*.d\
	libdparse/src/dparse/*.d\
	libdparse/src/std/experimental/*.d\
	dmarkdown/source/dmarkdown/*.d

IMPORTS:=-Ilibdparse/src\
	-Ilibddoc/src\
	-Idmarkdown/source\
	-Jstrings

FLAGS:=-O -gc -release -inline # keep -inline; not having it triggers an optimizer bug as pf 2.066

all: hmod pkg

hmod: bin/hmod

bin/hmod: $(SRC)
	dmd $(SRC) $(IMPORTS) $(FLAGS) -ofbin/hmod
	rm -f bin/*.o

clean:
	rm -rf bin/
	$(MAKE) -f makd/Makd.mak clean

doc:
	./bin/hmod src/

# Packaging configuration
pkg: $O/pkg-hmod.stamp
	$(MAKE) -f makd/Makd.mak pkg

$O/pkg-hmod.stamp: \
	hmod
