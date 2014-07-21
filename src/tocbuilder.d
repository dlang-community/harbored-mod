module tocbuilder;

import std.algorithm;
import std.stdio;

struct TocItem
{
	string name;
	string url;
	TocItem[] items;
	void write(File output, size_t indent = 0)
	{
		bool hasChildren = items.length != 0;
		foreach (i; 0 .. indent)
			output.write("    ");
		if (url !is null)
			output.writeln(`<li><a target="docframe" href="`, url, `">`, name, `</a></li>`);
		else
			output.writeln(`<li><span onclick="toggleChildren(this);"`,
				(indent == 0 ? ` class="expanded"` : ``), `>`, name, `</span>`);
		if (hasChildren)
		{
			foreach (i; 0 .. indent)
				output.write("    ");
			output.writeln(`<ul>`);
		}
		foreach (item; items)
			item.write(output, indent + 1);
		if (hasChildren)
		{
			foreach (i; 0 .. indent)
				output.write("    ");
			output.writeln(`</ul></li>`);
		}
	}
}

TocItem[] buildTree(string[] strings, string[string] links, size_t offset = 0)
{
	TocItem[] items;
	size_t i = 0;
	while (i < strings.length)
	{
		size_t j = i + 1;
		auto s = strings[i][offset .. $].findSplit(".");
		string prefix = s[0];
		string suffix = s[2];
		TocItem item;
		item.name = strings[i][offset .. offset + prefix.length];
		if (prefix.length != 0 && suffix.length != 0)
		{
			while (j < strings.length && strings[j][offset .. $].startsWith(prefix))
				j++;
			if (i < j)
			{
				size_t o = offset + prefix.length + 1;
				item.items = buildTree(strings[i .. j], links, o);
			}
		}
		else
			item.url = links[strings[i]];
		items ~= item;
		i = j;
	}
	sort!((a, b) => a.name < b.name)(items);
	return items;
}
