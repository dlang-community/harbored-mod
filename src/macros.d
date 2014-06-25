/**
 * D Documentation Generator
 * Copyright: © 2014 Economic Modeling Specialists, Intl.
 * Authors: Brian Schott
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt Boost License 1.0)
 */
module macros;

import std.regex;
import std.file;
import std.array;
import std.string;
import std.stdio;

/**
 * Reads macros from the file with the given name and stores them in the given
 * AA.
 */
void readMacroFile(string fileName, ref string[string] macros)
{
	if (!exists(fileName))
	{
		stderr.writeln("Could not read macro definitions from ", fileName,
			" because it does not exist");
		return;
	}
	string currentMacroName;
	foreach (line; File(fileName, "r").byLine(KeepTerminator.no))
	{
		if (line.strip.length == 0)
			continue;
		auto m = line.matchAll(`^([\w_]+)\s*=\s*(.+)?`);
		if (m.empty)
		{
			macros[currentMacroName] = format("%s\n%s", macros[currentMacroName], line);
			continue;
		}
		else
		{
			currentMacroName = m.front[1].idup;
			macros[currentMacroName] = m.front.length > 1 ? m.front[2].idup : "";
		}
	}
}
