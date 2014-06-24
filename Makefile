.PHONY: all clean

all:
	-mkdir bin 2> /dev/null
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
	-rm -r bin/
