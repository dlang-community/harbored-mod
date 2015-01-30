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

	Item[] publicImports;

	void writeImports(R, Writer)(ref R dst, Writer writer)
	{
		if(publicImports.empty) { return; }
		writer.writeSection(dst, 
		{
			writer.writeList(dst, "Public imports",
			{
				foreach(imp; publicImports) writer.writeListItem(dst,
				{
					if(imp.url is null)
					{
						dst.put(imp.name);
					}
					else writer.writeLink(dst, imp.url,
					{
						dst.put(imp.name);
					});
				});
			});
		}, "imports");
	}

	/// Write the table of members for a class/struct/module/etc.
	void write(R, Writer)(ref R dst, Writer writer)
	{
		if (aliases.empty && classes.empty && enums.empty && functions.empty
			&& interfaces.empty && structs.empty && templates.empty 
			&& values.empty && variables.empty)
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
		}, "members");
	}
}
