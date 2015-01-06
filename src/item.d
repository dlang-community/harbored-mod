/**
 * D Documentation Generator
 * Copyright: © 2014 Economic Modeling Specialists, Intl., © 2015 Ferdinand Majerech
 * Authors: Brian Schott, Ferdinand Majerech
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt Boost License 1.0)
 */
module item;


import formatter;
import std.algorithm;
import std.array: appender, empty, array;
import std.d.ast;
import std.string: format;



struct Item
{
	string url;
	string name;
	string summary;
	string type;

	/// AST node of the item. Only used for functions at the moment.
	const ASTNode node;
}

struct Members
{
	Item[] aliases;
	Item[] classes;
	Item[] enums;
	Item[] functions;
	Item[] interfaces;
	Item[] structs;
	Item[] templates;
	Item[] values;
	Item[] variables;

	/// Write the table of members for a class/struct/module/etc.
	void write(R, Writer)(ref R dst, Writer writer)
	{
		if (aliases.length == 0 && classes.length == 0 && enums.length == 0
			&& functions.length == 0 && interfaces.length == 0
			&& structs.length == 0 && templates.length == 0 && values.length == 0
			&& variables.length == 0)
		{
			return;
		}
		writer.writeSection(dst,
		{
			if(!enums.empty)      writer.writeItems(dst, enums, "Enums");
			if(!aliases.empty)    writer.writeItems(dst, aliases, "Aliases");
			if(!variables.empty)  writer.writeItems(dst, variables, "Variables");
			if(!functions.empty)  writer.writeItems(dst, functions, "Functions");
			if(!structs.empty)    writer.writeItems(dst, structs, "Structs");
			if(!interfaces.empty) writer.writeItems(dst, interfaces, "Interfaces");
			if(!classes.empty)    writer.writeItems(dst, classes, "Classes");
			if(!templates.empty)  writer.writeItems(dst, templates, "Templates");
			if(!values.empty)     writer.writeItems(dst, values, "Values");
		});
	}
}
