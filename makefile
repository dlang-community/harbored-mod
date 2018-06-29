.PHONY: all clean doc

all: hmod pkg

hmod: bin/hmod

bin/hmod: $(SRC)
	dub build

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
