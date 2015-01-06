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

	void write(R)(ref R dst)
	{
		dst.put(`<tr><td>`);
		void writeName()
		{
			dst.put(url == "#" ? name : `<a href="%s">%s</a>`.format(url, name));
		}

		// TODO print attributes for everything, and move it to separate function/s
		if(cast(FunctionDeclaration) node) with(cast(FunctionDeclaration) node)
		{
			// extremely inefficient, rewrite if too much slowdown
			string formatAttrib(T)(T attr)
			{
				auto writer = appender!(char[])();
				auto formatter = new HarboredFormatter!(typeof(writer))(writer);
				formatter.format(attr);
				auto str = writer.data.idup;
				writer.clear();
				import std.ascii: isAlpha;
				import std.conv: to;
				// Sanitize CSS class name for the attribute,
				auto strSane = str.filter!isAlpha.array.to!string;
				return `<span class="attr-` ~ strSane ~ `">` ~ str ~ `</span>`;
			}

			void writeSpan(C)(string class_, C content)
			{
				dst.put(`<span class="%s">%s</span>`.format(class_, content));
			}

			// Above the function name
			if(!attributes.empty)
			{
				dst.put(`<span class="extrainfo">`);
				writeSpan("attribs", attributes.map!(a => formatAttrib(a)).joiner(", "));
				dst.put(`</span>`);
			}


			// The actual function name
			writeName();


			// Below the function name
			dst.put(`<span class="extrainfo">`);
			if(!memberFunctionAttributes.empty)
			{
				writeSpan("method-attribs",
					memberFunctionAttributes.map!(a => formatAttrib(a)).joiner(", "));
			}
			// TODO storage classes don't seem to work. libdparse issue?
			if(!storageClasses.empty)
			{
				writeSpan("stor-classes", storageClasses.map!(a => formatAttrib(a)).joiner(", "));
			}
			dst.put(`</span>`);
		}
		else
		{
			writeName();
		}
		dst.put(`</td>`);

		dst.put(`<td>`);
		if (type !is null)
			dst.put(`<pre><code>%s</code></pre>`.format(type));
		dst.put(`</td><td>%s</td></tr>`.format(summary));
	}
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
	void write(R)(ref R dst)
	{
		if (aliases.length == 0 && classes.length == 0 && enums.length == 0
			&& functions.length == 0 && interfaces.length == 0
			&& structs.length == 0 && templates.length == 0 && values.length == 0
			&& variables.length == 0)
		{
			return;
		}

		dst.put(`<div class="section">`);
		if (enums.length > 0)
			write(dst, enums, "Enums");
		if (aliases.length > 0)
			write(dst, aliases, "Aliases");
		if (variables.length > 0)
			write(dst, variables, "Variables");
		if (functions.length > 0)
			write(dst, functions, "Functions");
		if (structs.length > 0)
			write(dst, structs, "Structs");
		if (interfaces.length > 0)
			write(dst, interfaces, "Interfaces");
		if (classes.length > 0)
			write(dst, classes, "Classes");
		if (templates.length > 0)
			write(dst, templates, "Templates");
		if (values.length > 0)
			write(dst, values, "Values");
		dst.put(`</div>`);
	}

private:
	/** Write a table of items in category specified 
	 *
	 * Params:
	 *
	 * dst   = Range to write to.
	 * items = Items the table will contain.
	 * name  = Name of the table, used in heading, i.e. category of the items. E.g.
	 *         "Functions" or "Variables" or "Structs".
	 */
	void write(R)(ref R dst, Item[] items, string name)
	{
		dst.put("<h2>%s</h2>".format(name));
		dst.put(`<table>`);
		foreach (ref i; items)
			i.write(dst);
		dst.put(`</table>`);
	}
}
