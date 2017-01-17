module tocbuilder;

import std.algorithm;
import std.array: back, empty;
import std.stdio;
import std.string: format;
import std.array;

struct TocItem
{
	private string name;
	private string url;
	private TocItem[] items;

	/// Computed by preCache() below ///

	/// Item name split by '.' This is an optimization (redundant with e.g. name.splitter)
	private string[] nameParts;
	/// Is this a package item?
	private bool isPackage;
	/// JS for opening/closing packages.
	private string spanJS;

	/// HTML content of the list item (can be wrapped in any <li> or <span>).
	private string listItem;

	/// Precompute any values that will be frequently reused.
	private void preCache()
	{
		import std.string: split;
		nameParts = name.split(".");
		isPackage = items.length != 0;
		if(url is null)
		{
			listItem = name;
		}
		else 
		{
			if(nameParts.length > 1)
			{
				listItem ~= nameParts[0 .. $ - 1].join(".") ~ ".";
			}
			listItem ~= `<a href="%s">%s</a>`.format(url, nameParts.back);
		}
		if(isPackage)
		{
			spanJS = ` onclick="show_hide('%s');"`.format(name);
		}
	}

	/** Write the TOC item.
	 *
	 * Params:
	 *
	 * dst        = Range to write to.
	 * moduleName = Name of the module/package in the documentation page of which
	 *              we're writing this TOC, if we're writing module/package documentation.
	 */
	public void write(R)(ref R dst, string moduleName = "")
	{
		// Is this TOC item the module/package the current documentation page
		// documents?
		const isSelected = name == moduleName;

		dst.put(`<li>`);
		const css = isPackage || isSelected;
		
		if(!css)
		{
			dst.put(listItem);
		}
		else
		{
			dst.put(`<span class="`);
			if(isPackage)  { dst.put("package"); }
			if(isSelected) { dst.put(" selected"); }
			dst.put(`"`);
			if(isPackage)  { dst.put(spanJS); }
			dst.put(`>`);
			dst.put(listItem);
			dst.put("</span>\n"); 
		}

		if(isPackage)
		{
			auto moduleParts = moduleName.splitter(".");
			const block = moduleParts.startsWith(nameParts);
			dst.put(`<ul id="`);
			dst.put(name);
			dst.put(`"`);
			if(moduleParts.startsWith(nameParts)) { dst.put(` style='display:block'`); }
			dst.put(">\n");

			foreach (item; items)
				item.write(dst, moduleName);
			// End a package's list of members
			dst.put("</ul>\n");
		}
		dst.put("</li>\n");
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
	foreach(ref item; items)
	{
	    item.preCache();
	}
	return items;
}
