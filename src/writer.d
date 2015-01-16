/**
 * D Documentation Generator
 * Copyright: © 2014 Economic Modeling Specialists, Intl., © 2015 Ferdinand Majerech
 * Authors: Brian Schott, Ferdinand Majerech
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt Boost License 1.0)
 */
module writer;


import config;
import ddoc.comments;
import formatter;
import std.algorithm;
import std.array: appender, empty, array, back, popBack;
import std.d.ast;
import std.file: exists, mkdirRecurse;
import std.path: buildPath;
import std.stdio;
import std.string: format;
import std.typecons;
import tocbuilder: TocItem;


class HTMLWriter
{
	/** Construct a HTMLWriter.
	 *
	 * Params:
	 *
	 * config        = Configuration data, including macros and the output directory.
	 * macros        = DDoc macro definitions indexed by macro name.
	 * searchIndex   = A file where the search information will be written
	 * tocItems      = Items of the table of contents to write into each documentation file.
	 * tocAdditional = Additional content for the table of contents sidebar.
	 */
	this(ref const Config config, string[string] macros, File searchIndex,
	     TocItem[] tocItems, string tocAdditional)
	{
		this.config        = &config;
		this.macros        = macros;
		this.searchIndex   = searchIndex;
		this.tocItems      = tocItems;
		this.tocAdditional = tocAdditional;
		this.processCode   = &processCodeDefault;
	}

	/** Get a link to the module for which we're currently writing documentation.
	 *
	 * See_Also: `prepareModule`
	 */
	string moduleLink() { return moduleLink_; }

	/** Get a link to a module.
	 *
	 * Note: this does not check if the module actually exists; calling moduleLink()
	 * for a nonexistent or undocumented module will return a link to a nonexistent
	 * file.
	 *
	 * Params:
	 *
	 * moduleNameParts = Name of the module containing the symbols, as an array of
	 *                   parts (e.g. ["std", "stdio"])
	 */
	string moduleLink(string[] moduleNameParts)
	{
		return moduleNameParts.buildPath ~ ".html";
	}

	/** Get a link to a symbol.
	 *
	 * Note: this does not check if the symbol actually exists; calling symbolLink()
	 * for a nonexistent or undocumented symbol will return a link to a nonexistent
	 * file.
	 *
	 * Params:
	 *
	 * moduleNameParts = Name of the module containing the symbols, as an array of
	 *                   parts (e.g. ["std", "stdio"])
	 * symbolNameParts = Name of the symbol in the module, as an array of parts.
	 * 
	 * Returns: Link to the file with documentation for the symbol.
	 */
	string symbolLink(string[] moduleNameParts, string[] symbolNameParts)
	{
		if(symbolNameParts.empty) { return moduleLink(moduleNameParts); }
		import std.string: join;
		return moduleNameParts.buildPath.buildPath(symbolNameParts.join(".") ~ ".html");
	}

	size_t moduleNameLength() { return moduleNameLength_; }

	/** Prepare for writing documentation for symbols in specified module.
	 *
	 * Initializes module-related file paths.
	 *
	 * Params:
	 *
	 * moduleNameParts = Parts of the module name, without the dots.
	 */
	void prepareModule(string[] moduleNameParts)
	{
		moduleFileBase_   = moduleNameParts.buildPath;
		moduleLink_       = moduleLink(moduleNameParts);
		moduleNameLength_ = moduleNameParts.length;
		
		// Not really absolute, just relative to working, not output, directory
		const moduleFileBaseAbs = config.outputDirectory.buildPath(moduleFileBase_);
		if (!moduleFileBaseAbs.exists)
		{
			moduleFileBaseAbs.mkdirRecurse();
		}
		assert(memberFileStack.empty,
			"prepareModule called before finishing previous module?");
		// Need a "parent" in the stack that will contain the module File
		memberFileStack.length = 1;
	}

	/** Finish writing documentation for current module.
	 *
	 * Must be called to ensure any open files are closed.
	 */
	void finishModule()
	{
		moduleFileBase_  = null;
		moduleLink_      = null;
		moduleNameLength_ = 0;
		popSymbol();
	}

	/** Writes HTML header information to the given range.
	 *
	 * Params:
	 *
	 * dst   = Range to write to
	 * title = The content of the HTML "title" element
	 * depth = The directory depth of the file. This is used for ensuring that
	 *         the "base" element is correct so that links resolve properly.
	 */
	void writeHeader(R)(ref R dst, string title, size_t depth)
	{
		import std.range: repeat;
		const rootPath = "../".repeat(depth).joiner.array;
		dst.put(
`<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8"/>
<link rel="stylesheet" type="text/css" href="%sstyle.css"/>
<script src="%shighlight.pack.js"></script>
<title>%s</title>
<base href="%s"/>
<script src="search.js"></script>
<script src="show_hide.js"></script>
</head>
<body>
<div class="main">
`.format(rootPath, rootPath, title, rootPath));
	}

	/** Writes the table of contents to provided range.
	 *
	 * Also starts the "content" <div>; must be called after writeBreadcrumbs(), 
	 * before writing main content.
	 *
	 * Params:
	 *
	 * dst        = Range to write to.
	 * moduleName = Name of the module or package documentation page of which we're
	 *              writing the TOC for.
	 */
	void writeTOC(R)(ref R dst, string moduleName = "")
	{
		void put(string str) { dst.put(str); dst.put("\n"); }
		put(`<div class="toc">`);
		if(tocAdditional !is null)
		{
			put(`<div class="toc-additional">`);
			put(tocAdditional);
			put(`</div>`);
		}
		writeList(dst, null,
		{
			// Buffering to scopeBuffer to avoid small file writes *and*
			// allocations
			import std.internal.scopebuffer;
			char[1024 * 64] buf;
			auto scopeBuf = ScopeBuffer!char(buf);
			scope(exit) { scopeBuf.free(); }

			foreach (t; tocItems) { t.write(scopeBuf, moduleName); }
			dst.put(scopeBuf[]);
		});
		put(`</div>`);
		put(`<div class="content">`);
	}

	/** Writes navigation breadcrumbs to the given range.
	 *
	 * Params:
	 *
	 * dst     = Range (e.g. appender) to write to.
	 * heading = Page heading (e.g. module name or "Main Page").
	 */
	void writeBreadcrumbs(R)(ref R dst, string heading)
	{
		void put(string str) { dst.put(str); dst.put("\n"); }
		put(`<div class="breadcrumbs">`);
		put(`<table id="results"></table>`);

		writeLink(dst, "index.html", { dst.put("⌂"); }, "home");
		put(`<input type="search" id="search" placeholder="Search" onkeyup="searchSubmit(this.value, event)"/>`);
		put(heading);
		put(`</div>`);
	}

	/** Writes navigation breadcrumbs for a symbol's documentation file.
	 *
	 * Params:
	 *
	 * dst              = Range to write to.
	 * symbolStack      = Name stack of the current symbol, including module name parts.
	 */
	void writeBreadcrumbs(R)(ref R dst, string[] symbolStack)
	{
		import std.array : join;
		import std.conv : to;
		import std.range : chain, only;
		import std.string: format;
		
		string heading;
		scope(exit) { writeBreadcrumbs(dst, heading); }

		assert(moduleNameLength_ <= symbolStack.length, "stack shallower than the current module?");
		size_t i;
		
		string link()
		{
			assert(i + 1 >= moduleNameLength_, "unexpected value of i");
			return symbolLink(symbolStack[0 .. moduleNameLength], 
			                  symbolStack[moduleNameLength .. i + 1]);
		}

		// Module
		{
			heading ~= "<small>";
			scope(exit) { heading ~= "</small>"; }
			for(; i + 1 < moduleNameLength_; ++i)
			{
				heading ~= symbolStack[i] ~ ".";
			}
			// Module link if the module is a parent of the current page.
			if(i + 1 < symbolStack.length)
			{
				heading ~= `<a href=%s>%s</a>.`.format(link(), symbolStack[i]);
				++i;
			}
			// Just the module name, not a link, if we're at the module page.
			else
			{
				heading ~= symbolStack[i];
				return;
			}
		}

		// Class/Function/etc. in the module
		heading ~= `<span class="highlight">`;
		// The rest of the stack except the last element (parents of current page).
		for(; i + 1 < symbolStack.length; ++i)
		{
			heading  ~= `<a href=%s>%s</a>.`.format(link(), symbolStack[i]);
		}
		// The last element (no need to link to the current page).
		heading ~= symbolStack[i];
		heading ~= `</span>`;
	}

	/** Writes a doc comment to the given range and returns the summary text.
	 *
	 * Params:
	 * dst          = Range to write the comment to.
	 * comment      = The comment to write
	 * prevComments = Previously encountered comments. This is used for handling
	 *                "ditto" comments. May be null.
	 * functionBody = A function body used for writing contract information. May be null.
	 * testdocs     = Pairs of unittest bodies and unittest doc comments. May be null.
	 *
	 * Returns: the summary from the given comment
	 */
	string readAndWriteComment(R)
		(ref R dst, string comment, Comment[] prevComments = null,
		 const FunctionBody functionBody = null,
		 Tuple!(string, string)[] testDocs = null)
	{
		import std.d.lexer : unDecorateComment;
		auto app = appender!string();
		comment.unDecorateComment(app);
	//	writeln(comment, " undecorated to ", app.data);

		Comment c = parseComment(app.data, macros);
		immutable ditto = c.isDitto;

		// Finds code blocks generated by libddoc and calls processCode() on them,
		string processCodeBlocks(string remaining)
		{
			auto codeApp = appender!string();
			do
			{
				auto parts = remaining.findSplit("<pre><code>");
				codeApp.put(parts[0]);
				codeApp.put(parts[1]); //<code><pre>

				parts = parts[2].findSplit("</code></pre>");
				codeApp.put(processCode(parts[0]));
				codeApp.put(parts[1]); //</code></pre>
				remaining = parts[2];
			}
			while(!remaining.empty);
			return codeApp.data;
		}

		// Run sections through markdown.
		foreach(ref section; c.sections) 
		{
			import dmarkdown;
			// We want to enable '***' subheaders and to post-process code
			// for cross-referencing.
			auto mdSettings = new MarkdownSettings();
			mdSettings.flags = MarkdownFlags.alternateSubheaders;
			mdSettings.processCode = processCode;

			// Ensure param descriptions run through Markdown
			if(section.name == "Params") foreach(ref kv; section.mapping)
			{
				kv[1] = filterMarkdown(kv[1], mdSettings);
			}
			// Do not run code examples through markdown.
			//
			// We could also check for section.name == "Examples" but code blocks can
			// be even outside examples. Alternatively, we could look for *multi-line*
			// <pre>/<code> blocks, or, before parsing comments, for "---" pairs.
			//
			// Alternatively, dmarkdown could be changed to ignore <pre>/<code>
			// blocks.
			if(!section.content.canFind("<pre><code>")) 
			{
				section.content = filterMarkdown(section.content, mdSettings);
			}
			else
			{
				section.content = processCodeBlocks(section.content);
			}
		}

		if (prevComments.length > 0)
		{
			if (ditto)
				c = prevComments[$ - 1];
			else
				prevComments[$ - 1] = c;
		}
		
		
		writeComment(dst, c, functionBody);

		// Shortcut to write text followed by newline
		void put(string str) { dst.put(str); dst.put("\n"); }
		// Find summary and return value info
		string rVal = "";
		if (c.sections.length && c.sections[0].name == "Summary")
			rVal = c.sections[0].content;
		else foreach (section; c.sections.find!(s => s.name == "Returns"))
		{
			rVal = "Returns: " ~ section.content;
		}
		if (testDocs !is null) foreach (doc; testDocs)
		{
	//		writeln("Writing a unittest doc comment");
			import std.string : outdent;
			writeSection(dst,
			{
				put(`<h2>Example</h2>`);
				auto docApp = appender!string();
				doc[1].unDecorateComment(docApp);
				Comment dc = parseComment(docApp.data, macros);
				writeComment(dst, dc);
				writeCodeBlock(dst, { dst.put(processCode(outdent(doc[0]))); } );
			});
		}
		return rVal;
	}


	/** Writes attributes to the range dst using formatter to format code.
	 *
	 * Params:
	 *
	 * dst       = Range to write to.
	 * formatter = Formatter to format the attributes with.
	 * attrs     = Attributes to write.
	 */
	void writeAttributes(R, F)(ref R dst, F formatter, const(Attribute)[] attrs)
	{
		import std.d.lexer: IdType, isProtection, tok;
		IdType protection;
		foreach (a; attrs.filter!(a => a.attribute.type.isProtection))
		{
			protection = a.attribute.type;
		}
		switch (protection)
		{
			case tok!"private":   dst.put("private ");   break;
			case tok!"package":   dst.put("package ");   break;
			case tok!"protected": dst.put("protected "); break;
			default:              dst.put("public ");    break;
		}
		foreach (a; attrs.filter!(a => !a.attribute.type.isProtection))
		{
			formatter.format(a);
			dst.put(" ");
		}
	}

	/** Writes a code block to range dst, using blockCode to write code block contents.
	 *
	 * Params:
	 *
	 * dst       = Range to write to.
	 * blockCode = Function that will write the code block contents (presumably also
	 *             into dst).
	 */
	void writeCodeBlock(R)(ref R dst, void delegate() blockCode)
	{
		dst.put(`<pre><code>`);
		blockCode();
		dst.put("\n</code></pre>\n");
	}

	/** Writes a section to range dst, using sectionCode to write section contents.
	 *
	 * Params:
	 *
	 * dst         = Range to write to.
	 * blockCode   = Function that will write the section contents (presumably also
	 *               into dst).
	 * extraStyles = Extra style classes to use in the section, separated by spaces.
	 *               May be ignored by non-HTML writers.
	 */
	void writeSection(R)(ref R dst, void delegate() sectionCode, string extraStyles = "")
	{
		dst.put(`<div class="section%s">`
		        .format(extraStyles is null ? "" : " " ~ extraStyles));
		sectionCode();
		dst.put("\n</div>\n");
	}

	/** Writes an unordered list to range dst, using listCode to write list contents.
	 *
	 * Params:
	 *
	 * dst      = Range to write to.
	 * name     = Name of the list, if any. Will be used as heading if specified.
	 * listCode = Function that will write the list contents.
	 */
	void writeList(R)(ref R dst, string name, void delegate() listCode)
	{
		if(name !is null) { dst.put(`<h2>%s</h2>`.format(name)); }
		dst.put(`<ul>`);
		listCode();
		dst.put("\n</ul>\n");
	}

	/** Writes a list item to range dst, using itemCode to write list contents.
	 *
	 * Params:
	 *
	 * dst      = Range to write to.
	 * itemCode = Function that will write the item contents.
	 */
	void writeListItem(R)(ref R dst, void delegate() itemCode)
	{
		dst.put(`<li>`);
		itemCode();
		dst.put("</li>");
	}

	/** Writes a link to range dst, using linkCode to write link text (but not the
	 * link itself).
	 *
	 * Params:
	 *
	 * dst         = Range to write to.
	 * link        = Link (URL) to write.
	 * linkCode    = Function that will write the link text.
	 * extraStyles = Extra style classes to use for the link, separated by spaces.
	 *               May be ignored by non-HTML writers.
	 */
	void writeLink(R)(ref R dst, string link, void delegate() linkCode, string extraStyles = "")
	{
		const styles = extraStyles.empty ? "" : ` class="%s"`.format(extraStyles);
		dst.put(`<a href="%s"%s>`.format(link, styles));
		linkCode();
		dst.put("</a>");
	}

	/** Write a separator (e.g. between two overloads of a function)
	 *
	 * In HTMLWriter this is a horizontal line.
	 */
	void writeSeparator(R)(ref R dst)
	{
		dst.put("<hr/>");
	}

	import item;
	/** Write a table of items of specified category.
	 *
	 * Params:
	 *
	 * dst      = Range to write to.
	 * items    = Items the table will contain.
	 * category = Category of the items, used in heading, E.g. "Functions" or
	 *            "Variables" or "Structs".
	 */
	void writeItems(R)(ref R dst, Item[] items, string category)
	{
		dst.put("<h2>%s</h2>".format(category));
		dst.put(`<table>`);
		foreach (ref i; items) { writeItemEntry(dst, i); }
		dst.put(`</table>`);
	}

	/** Formats an AST node to a string.
	 */
	string formatNode(T)(const T t)
	{
		auto writer = appender!string();
		auto formatter = newFormatter(writer);
		scope(exit) destroy(formatter.sink);
		formatter.format(t);
		return writer.data;
	}

	auto newFormatter(R)(ref R dst)
	{
		return new HarboredFormatter!R(dst, processCode);
	}

	auto pushSymbol(string[] symbolStack, ref bool first, ref string itemURL)
	{
		import std.conv: to;
		memberFileStack.length = memberFileStack.length + 1;

		assert(symbolStack.length >= moduleNameLength_,
		       "symbol stack shorter than module name");

		auto tail = symbolStack[moduleNameLength_ .. $];
		// Path relative to output directory
		const docFileName = tail.empty
			? moduleFileBase_ ~ ".html"
			: moduleFileBase_.buildPath(tail.joiner(".").array.to!string) ~ ".html";

		addSearchEntry(symbolStack);

		// The second last element of memberFileStack
		immutable size_t i = memberFileStack.length - 2;
		assert (i < memberFileStack.length, "%s %s".format(i, memberFileStack.length));
		auto p = docFileName in memberFileStack[i];
		first = p is null;
		itemURL = docFileName;
		if (first)
		{
			first = true;
			auto f = File(config.outputDirectory.buildPath(docFileName), "w");
			memberFileStack[i][docFileName] = f;

			auto fileWriter = f.lockingTextWriter;
			return f.lockingTextWriter;
		}
		else
			return p.lockingTextWriter;
	}

	void popSymbol()
	{
		auto files = memberFileStack.back; 
		foreach (f; files)
		{
			f.writeln(HTML_END);
			f.close();
		}
		destroy(files);
		memberFileStack.popBack();
	}

private:
	/** Add an entry for JavaScript search for the symbol with specified name stack.
	 * 
	 * symbolStack = Name stack of the current symbol, including module name parts.
	 */
	void addSearchEntry(string[] symbolStack)
	{
		import std.path: buildPath;
		import std.conv: to;
		
		const symbol = symbolStack.joiner(".").array;
		const symbolInModule = symbolStack[moduleNameLength_ .. $].joiner(".").array;
		const fileName = moduleFileBase_.buildPath(symbolInModule.to!string) ~ ".html";
		searchIndex.writefln(`{"%s" : "%s"},`, symbol, fileName);
	}

	void writeComment(R)(ref R dst, Comment comment, const FunctionBody functionBody = null)
	{
	//		writeln("writeComment: ", comment.sections.length, " sections.");
		// Shortcut to write text followed by newline
		void put(string str) { dst.put(str); dst.put("\n"); }

		size_t i;
		for (i = 0; i < comment.sections.length && (comment.sections[i].name == "Summary"
			|| comment.sections[i].name == "description"); i++)
		{
			writeSection(dst, { put(comment.sections[i].content); });
		}

		if (functionBody !is null)
		{
			writeContracts(dst, functionBody.inStatement, functionBody.outStatement);
		}


		const seealsoNames = ["See_also", "See_Also", "See also", "See Also"];
		foreach (section; comment.sections[i .. $])
		{
			if (seealsoNames.canFind(section.name) || section.name == "Macros")
				continue;

			// Note sections a use different style
			const isNote = section.name == "Note";
			string extraClasses;

			if(isNote) { extraClasses ~= "note"; }

			writeSection(dst, 
			{
				if (section.name != "Summary" && section.name != "Description")
				{
					dst.put("<h2>");
					dst.put(prettySectionName(section.name));
					put("</h2>");
				}
				if(isNote) { put(`<div class="note-content">`); }
				scope(exit) if(isNote) { put(`</div>`); }

				if (section.name == "Params")
				{
					put(`<table class="params">`);
					foreach (kv; section.mapping)
					{
						dst.put(`<tr class="param"><td class="paramName">`);
						dst.put(kv[0]);
						dst.put(`</td><td class="paramDoc">`);
						dst.put(kv[1]);
						put("</td></tr>");
					}
					dst.put("</table>");
				}
				else
				{
					put(section.content);
				}
			}, extraClasses);
		}

		// Merge any see also sections into one, and draw it with different style than
		// other sections.
		{
			auto seealsos = comment.sections.filter!(s => seealsoNames.canFind(s.name));
			if(!seealsos.empty)
			{
				put(`<div class="section seealso">`);
				dst.put("<h2>");
				dst.put(prettySectionName(seealsos.front.name));
				put("</h2>");
				put(`<div class="seealso-content">`);
				foreach(section; seealsos)
				{
					put(section.content);
				}
				put(`</div>`);
				put(`</div>`);
			}
		}
	}

	void writeContracts(R)(ref R dst, const InStatement inStatement,
		const OutStatement outStatement)
	{
		if (inStatement is null && outStatement is null)
			return;
		writeSection(dst, 
		{
			dst.put(`<h2>Contracts</h2>`);
			writeCodeBlock(dst, 
			{
				auto formatter = newFormatter(dst);
				scope(exit) formatter.sink = R.init;
				if (inStatement !is null)
				{
					formatter.format(inStatement);
					if (outStatement !is null)
						dst.put("\n");
				}
				if (outStatement !is null)
					formatter.format(outStatement);
			});
		});
	}

	void writeItemEntry(R)(ref R dst, ref Item item)
	{
		dst.put(`<tr><td>`);
		void writeName()
		{
			dst.put(item.url == "#" 
				? item.name : `<a href="%s">%s</a>`.format(item.url, item.name));
		}

		// TODO print attributes for everything, and move it to separate function/s
		if(cast(FunctionDeclaration) item.node) with(cast(FunctionDeclaration) item.node)
		{
			// extremely inefficient, rewrite if too much slowdown
			string formatAttrib(T)(T attr)
			{
				auto writer = appender!(char[])();
				auto formatter = newFormatter(writer);
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
		if (item.type !is null)
		{
			writeCodeBlock(dst, { dst.put(item.type); });
		}
		dst.put(`</td><td>%s</td></tr>`.format(item.summary));
	}

	/// Default processCode function.
	string processCodeDefault(string str) @safe nothrow { return str; }

	/// Function to process inline code and code blocks with (used for cross-referencing).
	public string delegate(string) @safe nothrow processCode;

private:
	const(Config)* config;
	string[string] macros;
	File searchIndex;
	TocItem[] tocItems;
	string tocAdditional;

	/** Stack of associative arrays.
	 *
	 * Each level of the stack contains files of documentation pages of members of
	 * the symbol at that level; e.g. memberFileStack[0] contains the module
	 * documentation file, memberFileStack[1] doc pages of the module's child classes,
	 * etc; memberFileStack.back contains the doc page currently being written.
	 *
	 * When popSymbol() is called, all doc page files of that symbol's members are 
	 * closed (they must be kept open until then to ensure overloads are put into the
	 * same file).
	 */
	File[string][] memberFileStack;

	string moduleFileBase_;
	/// Path to the HTML file relative to the output directory.
	string moduleLink_;
	// Name length of the module (e.g. 2 for std.stdio)
	size_t moduleNameLength_;
}


private:

enum HTML_END = `
<script>hljs.initHighlightingOnLoad();</script>
</div>
</div>
</body>
</html>`;

string prettySectionName(string sectionName)
{
	switch (sectionName)
	{
		case "See_also", "See_Also", "See also", "See Also": return "See Also:";
		case "Note":   return "Note:";
		case "Params": return "Parameters";
		default:       return sectionName;
	}
}
