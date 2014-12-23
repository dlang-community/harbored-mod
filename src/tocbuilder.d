module tocbuilder;

import std.algorithm;
import std.array: empty;
import std.stdio;

struct TocItem
{
	string name;
	string url;
	TocItem[] items;

	void write(File output)
	{
		bool hasChildren = items.length != 0;
		if (url !is null)
		{
			output.writeln(`<li><a href="`, url, `">`, name, `</a></li>`);
		}
		else
		{
			output.writeln(`<li><span class="package">`, name, `</span>`);
		}
		if (hasChildren)
		{
			output.writeln(`<ul>`);
		}
		foreach (item; items)
			item.write(output);
		if (hasChildren)
		{
			output.writeln(`</ul></li>`);
		}
	}
}

TocItem[] buildTree(string[] strings, string[string] links, const size_t offset = 0)
{
	TocItem[] items;
	size_t i = 0;
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
		items ~= item;
		i = j;
	}
	sort!((a, b) => a.name < b.name)(items);
	return items;
}
