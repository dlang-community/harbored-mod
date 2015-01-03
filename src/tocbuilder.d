module tocbuilder;

import std.algorithm;
import std.array: back, empty;
import std.stdio;
import std.string: format;
import std.array;

struct TocItem
{
	string name;
	string url;
	TocItem[] items;

	void write(R)(ref R dst)
	{
		// Shortcut to write text followed by newline
		void put(string str) { dst.put(str); dst.put("\n"); }

		import std.string: split;
		bool isPackage = items.length != 0;
		dst.put(`<li>`);
		if (isPackage)
		{
			dst.put(`<span class="package">`);
		}
		if (url !is null)
		{
			auto parts = name.split(".");
			dst.put(parts.length > 1 ?
				`<small>%s.</small>`.format(parts[0 .. $ - 1].joiner(".")) : "");
			dst.put(`<a href="%s">%s</a>`.format(url, parts.back));
		}
		else
		{
			dst.put(name);
		}
		if (isPackage)
		{
			put(`</span>`);
			put(`<ul>`);
			foreach (item; items)
				item.write(dst);
			// End a package's list of members
			put(`</ul>`);
		}
		put(`</li>`);
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
