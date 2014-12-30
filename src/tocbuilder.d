module tocbuilder;

import std.algorithm;
import std.array: back, empty;
import std.stdio;
import std.string;
import std.range;

struct TocItem
{
	string name;
	string url;
	TocItem[] items;

	void write(File output)
	{
		import std.string: split;
		
		bool hasChildren = items.length != 0;
		output.writeln(`<li>`);
		if (hasChildren)
		{
			output.writeln(`<span class="package">`);
		}
		if (url !is null)
		{
			auto parts = name.split(".");
			output.writeln(
				parts.length > 1 ?
				`<small>`, parts[0 .. $ - 1].joiner("."), `.</small>` : "",
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
			output.writeln(`<ul>`);
		}
		foreach (item; items)
			item.write(output);
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

	sort!((a, b) => (a.name < b.name))(items);
	return items;
}
