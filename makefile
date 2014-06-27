.PHONY: all clean

all:
	dmd\
		src/*.d\
		libddoc/src/ddoc/*.d\
		libdparse/src/std/*.d\
		libdparse/src/std/d/*.d\
		-Ilibdparse/src\
		-Ilibddoc/src\
		-Jstrings\
		-ofbin/harbored
	-rm bin/*.o

clean:
	rm -rf bin/
