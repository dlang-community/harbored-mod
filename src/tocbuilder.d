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

	/** Write the TOC item.
	 *
	 * Params:
	 *
	 * dst        = Range to write to.
	 * moduleName = Name of the module/package in the documentation page of which
	 *              we're writing this TOC, if we're writing module/package documentation.
	 */
	void write(R)(ref R dst, string moduleName = "")
	{
		// Shortcut to write text followed by newline
		void put(string str) { dst.put(str); dst.put("\n"); }

		import std.string: split;
		auto nameParts   = name.split(".");
		const moduleParts = moduleName.split(".");

		const isPackage  = items.length != 0;
		// Is this TOC item the module/package the current documentation page
		// documents?
		const isSelected = nameParts == moduleParts;

		dst.put(`<li>`);
		string[] cssClasses = (isPackage  ? ["package"]  : []) ~
		                      (isSelected ? ["selected"] : []);
		
		if (!cssClasses.empty)
		{
			const js = isPackage ? ` onclick="show_hide('%s');"`.format(name) : "";
			dst.put(`<span class="%s"%s>`.format(cssClasses.join(" "), js));
		}

		if (url !is null)
		{
			dst.put(nameParts.length > 1 ?
				`<small>%s.</small>`.format(nameParts[0 .. $ - 1].joiner(".")) : "");
			dst.put(`<a href="%s">%s</a>`.format(url, nameParts.back));
		}
		else
		{
			dst.put(name);
		}

		if (!cssClasses.empty)
		{
			put(`</span>`); 
		}

		if(isPackage)
		{
			const display = moduleParts.startsWith(nameParts) ?
			                " style='display:block;'" : "";
			
			put(`<ul id="%s"%s>`.format(name, display));
			foreach (item; items)
				item.write(dst, moduleName);
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
