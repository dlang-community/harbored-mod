module tocbuilder;

import std.algorithm;
import std.array: back, empty;
import std.stdio;
import std.array;

struct TocItem
{
	string name;
	string url;
	TocItem[] items;

	void write(File output, string moduleName = "")
	{
		import std.string: split;
		
		bool hasChildren = items.length != 0;

        	auto parts = name.split(".");
        	auto moduleParts = moduleName.split(".");
        
        	auto selected = false;
        
        	if( moduleParts.length >= parts.length )
            	if( parts == moduleParts )
                	selected = true;

		output.writeln(`<li>`);
		if (hasChildren || selected)
		{
            		string[] selected_class;
            		if( hasChildren )
                		selected_class ~= "package";
            		if( selected )
                		selected_class ~= "selected";
			output.writefln(`<span class="%s" onclick="show_hide('%s');">`, selected_class.join(" "), name);
		}
		if (url !is null)
		{
			output.writeln(
				parts.length > 1 ?
				`<small>` ~ parts[0 .. $ - 1].join(".") ~ `.</small>` : "",
				`<a href="`, url, `">`, parts.back, `</a>`);
		}
		else
		{
			output.writeln(name);
		}
		if (hasChildren)
		{
			output.writeln(`</span>`);
		}
		if (hasChildren)
		{
            		auto display = "";
            
            		if( moduleParts.length >= parts.length )
                		if( moduleParts.startsWith( parts ) )
                    			display = " style='display:block;'";
            
            		output.writefln( `<ul id=%s%s>`, name, display );
		}
		foreach (item; items)
			item.write(output, moduleName);
		if (hasChildren)
		{
			output.writeln(`</ul>`);
		}
		output.writeln(`</li>`);
	}
}

TocItem[] buildTree(string[] strings, string[string] links, const size_t offset = 0)
{
	TocItem[] items;
	size_t i = 0;
	strings.sort();
	while (i < strings.length)
	{
		size_t j = i + 1;
		auto s = strings[i][offset .. $].findSplit(".");
		const string prefix = s[0];
		string suffix = s[2];
		TocItem item;
		if (prefix.length != 0 && suffix.length != 0)
		{
			while (j < strings.length && strings[j][offset .. $].startsWith(prefix ~ s[1]))
				j++;
			if (i < j)
			{
				size_t o = offset + prefix.length + 1;
				item.items = buildTree(strings[i .. j], links, o);
			}
		}
		else
			item.url = links[strings[i]];

		// short name (only module, no package):
		// item.name = strings[i][offset .. offset + prefix.length];
		item.name = strings[i][0 .. item.items.empty ? $ : offset + prefix.length];

		if(items.length > 0 && items.back.name == item.name)
		{
			items.back.items = item.items;
		}
		else
		{
			items ~= item;
		}

		i = j;
	}
	return items;
}
