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
import std.conv: to;
import std.d.ast;
import std.file: exists, mkdirRecurse;
import std.path: buildPath;
import std.stdio;
import std.string: format, outdent, split;
import std.typecons;
import symboldatabase;
import tocbuilder: TocItem;

// NOTE: as of DMD 2.066, libddoc has a bug when using flags `-O -gc -release` but not
//       when we add `-inline` to it: words in macros are duplicated.
//       This is because for whatever reason, `currentApp` and `zeroApp` in
//       `ddoc.macros.collectMacroArguments()` are merged into one instance.

// Only used for shared implementation, not interface (could probably use composition too)
private class HTMLWriterBase(alias symbolLink)
{
	/** Construct a HTMLWriter.
	 *
	 * Params:
	 *
	 * config         = Configuration data, including macros and the output directory.
	 *                  A non-const reference is needed because libddoc wants
	 *                  a non-const reference to macros for parsing comments, even
	 *                  though it doesn't modify the macros.
	 * searchIndex    = A file where the search information will be written
	 * tocItems       = Items of the table of contents to write into each documentation file.
	 * tocAdditionals = Additional pieces of content for the table of contents sidebar.
	 */
	this(ref Config config, File searchIndex,
	     TocItem[] tocItems, string[] tocAdditionals)
	{
		this.config         = &config;
		this.macros         = config.macros;
		this.searchIndex    = searchIndex;
		this.tocItems       = tocItems;
		this.tocAdditionals = tocAdditionals;
		this.processCode    = &processCodeDefault;
	}

	/** Get a link to the module for which we're currently writing documentation.
	 *
	 * See_Also: `prepareModule`
	 */
	final string moduleLink() { return moduleLink_; }

	/** Get a link to a module.
	 *
	 * Note: this does not check if the module exists; calling moduleLink() for a
	 * nonexistent or undocumented module will return a link to a nonexistent file.
	 *
	 * Params: moduleNameParts = Name of the module containing the symbols, as an array
	 *                           of parts (e.g. ["std", "stdio"])
	 */
	final string moduleLink(string[] moduleNameParts)
	{
		return moduleNameParts.buildPath ~ ".html";
	}

	final size_t moduleNameLength() { return moduleNameLength_; }

	/** Prepare for writing documentation for symbols in specified module.
	 *
	 * Initializes module-related file paths and creates the directory to write
	 * documentation of module members into.
	 *
	 * Params: moduleNameParts = Parts of the module name, without the dots.
	 */
	final void prepareModule(string[] moduleNameParts)
	{
		moduleFileBase_   = moduleNameParts.buildPath;
		moduleLink_       = moduleLink(moduleNameParts);
		moduleNameLength_ = moduleNameParts.length;

		// Not really absolute, just relative to working, not output, directory
		const moduleFileBaseAbs = config.outputDirectory.buildPath(moduleFileBase_);
		// Create directory to write documentation for module members.
		if (!moduleFileBaseAbs.exists) { moduleFileBaseAbs.mkdirRecurse(); }
		assert(symbolFileStack.empty,
		       "prepareModule called before finishing previous module?");
		// Need a "parent" in the stack that will contain the module File
		symbolFileStack.length = 1;
	}

	/** Finish writing documentation for current module.
	 *
	 * Must be called to ensure any open files are closed.
	 */
	final void finishModule()
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
	final void writeHeader(R)(ref R dst, string title, size_t depth)
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

	/** Write the main module list (table of module links and descriptions).
	 *
	 * Written to the main page.
	 *
	 * Params:
	 *
	 * dst      = Range to write to.
	 * database = Symbol database aware of all modules.
	 * 
	 */
	final void writeModuleList(R)(ref R dst, SymbolDatabase database)
	{
		writeln("writeModuleList called");
		
		void put(string str) { dst.put(str); dst.put("\n"); }

		writeSection(dst, 
		{
			// Sort the names by alphabet
			// duplicating should be cheap here; there is only one module list
			import std.algorithm: sort;
			auto sortedModuleNames = sort(database.moduleNames.dup);
			dst.put(`<h2>Module list</h2>`);
			put(`<table class="module-list">`);
			foreach(name; sortedModuleNames)
			{
				dst.put(`<tr><td class="module-name">`);
				writeLink(dst, database.moduleNameToLink[name],
				          { dst.put(name); });
				dst.put(`</td><td>`);
				dst.put(processMarkdown(database.moduleData(name).summary));
				put("</td></tr>");
			}
			put(`</table>`);
		} , "imports");

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
	final void writeTOC(R)(ref R dst, string moduleName = "")
	{
		void put(string str) { dst.put(str); dst.put("\n"); }
		const link = moduleName ? moduleLink(moduleName.split(".")) : "";
		put(`<div class="sidebar">`);
		// Links allowing to show/hide the TOC.
		put(`<a href="%s#hide-toc" class="hide" id="hide-toc">&#171;</a>`.format(link));
		put(`<a href="%s#show-toc" class="show" id="show-toc">&#187;</a>`.format(link));
		put(`<div id="toc-id" class="toc">`);
		import std.range: retro;
		foreach(text; tocAdditionals.retro)
		{
			put(`<div class="toc-additional">`); put(text); put(`</div>`);
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
		put(`</div></div>`);
		put(`<div class="content">`);
	}

	/** Writes navigation breadcrumbs to the given range.
	 *
	 * For symbols, use the other writeBreadcrumbs overload.
	 *
	 * Params:
	 *
	 * dst     = Range (e.g. appender) to write to.
	 * heading = Page heading (e.g. module name or "Main Page").
	 */
	final void writeBreadcrumbs(R)(ref R dst, string heading)
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
	void writeBreadcrumbs(R)(ref R dst, string[] symbolStack, SymbolDatabase database)
	{
		string heading;
		scope(exit) { writeBreadcrumbs(dst, heading); }

		assert(moduleNameLength_ <= symbolStack.length, "stack shallower than the current module?");
		size_t depth;

		string link()
		{
			assert(depth + 1 >= moduleNameLength_, "unexpected value of depth");
			return symbolLink(database.symbolStack(
			                  symbolStack[0 .. moduleNameLength],
			                  symbolStack[moduleNameLength .. depth + 1]));
		}

		// Module
		{
			heading ~= "<small>";
			scope(exit) { heading ~= "</small>"; }
			for(; depth + 1 < moduleNameLength_; ++depth)
			{
				heading ~= symbolStack[depth] ~ ".";
			}
			// Module link if the module is a parent of the current page.
			if(depth + 1 < symbolStack.length)
			{
				heading ~= `<a href=%s>%s</a>.`.format(link(), symbolStack[depth]);
				++depth;
			}
			// Just the module name, not a link, if we're at the module page.
			else
			{
				heading ~= symbolStack[depth];
				return;
			}
		}

		// Class/Function/etc. in the module
		heading ~= `<span class="highlight">`;
		// The rest of the stack except the last element (parents of current page).
		for(; depth + 1 < symbolStack.length; ++depth)
		{
			heading  ~= `<a href=%s>%s</a>.`.format(link(), symbolStack[depth]);
		}
		// The last element (no need to link to the current page).
		heading ~= symbolStack[depth];
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
	final string readAndWriteComment(R)
		(ref R dst, string comment, Comment[] prevComments = null,
		 const FunctionBody functionBody = null,
		 Tuple!(string, string)[] testDocs = null)
	{
		if(comment.empty) { return null; }

		import core.exception: RangeError;
		try
		{
			return readAndWriteComment_(dst, comment, prevComments, functionBody, testDocs);
		}
		catch(RangeError e)
		{
			writeln("failed to process comment: ", e);
			dst.put("<div class='error'><h3>failed to process comment</h3>\n"
			        "\n<pre>%s</pre>\n<h3>error</h3>\n<pre>%s</pre></div>"
			        .format(comment, e));
			return null;
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
		dst.put(`<pre><code>`); blockCode(); dst.put("\n</code></pre>\n");
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
		dst.put(`<ul>`); listCode(); dst.put("\n</ul>\n");
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
		dst.put(`<li>`); itemCode(); dst.put("</li>");
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
		dst.put(`<a href="%s"%s>`.format(link, styles)); linkCode(); dst.put("</a>");
	}

	final auto newFormatter(R)(ref R dst)
	{
		return new HarboredFormatter!R(dst, processCode);
	}

	final void popSymbol()
	{
		auto files = symbolFileStack.back;
		foreach (f; files)
		{

			f.writeln(`<script>hljs.initHighlightingOnLoad();</script>`);
			f.writeln(HTML_END);
			f.close();
		}
		destroy(files);
		symbolFileStack.popBack();
	}

	/// Default processCode function.
	final string processCodeDefault(string str) @safe nothrow { return str; }

	/// Function to process inline code and code blocks with (used for cross-referencing).
	public string delegate(string) @safe nothrow processCode;

protected:
	/** Add an entry for JavaScript search for the symbol with specified name stack.
	 *
	 * symbolStack = Name stack of the current symbol, including module name parts.
	 */
	final void addSearchEntry(SymbolStack)(SymbolStack symbolStack)
	{
		const symbol = symbolStack.map!(s => s.name).joiner(".").array;
		searchIndex.writefln(`{"%s" : "%s"},`, symbol, symbolLink(symbolStack));
	}

	/** If markdown enabled, run input through markdown and return it. Otherwise
	 * return input unchanged.
	 */
	final string processMarkdown(string input)
	{
		if(config.noMarkdown) { return input; }
		import dmarkdown;
		// We want to enable '***' subheaders and to post-process code
		// for cross-referencing.
		auto mdSettings = new MarkdownSettings();
		mdSettings.flags = MarkdownFlags.alternateSubheaders |
		                   MarkdownFlags.disableUnderscoreEmphasis;
		mdSettings.processCode = processCode;
		return filterMarkdown(input, mdSettings);
	}


	/// See_Also: `readAndWriteComment`
	final string readAndWriteComment_(R)
		(ref R dst, string comment, Comment[] prevComments,
		 const FunctionBody functionBody, Tuple!(string, string)[] testDocs)
	{
		import std.d.lexer : unDecorateComment;
		auto app = appender!string();
		comment.unDecorateComment(app);
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
			// Ensure param descriptions run through Markdown
			if(section.name == "Params") foreach(ref kv; section.mapping)
			{
				kv[1] = processMarkdown(kv[1]);
			}
			// Do not run code examples through markdown.
			//
			// We could check for section.name == "Examples" but code blocks can be
			// outside examples. Alternatively, we could look for *multi-line*
			// <pre>/<code> blocks, or, before parsing comments, for "---" pairs.
			// Or, dmarkdown could be changed to ignore <pre>/<code> blocks.
			const isCode = section.content.canFind("<pre><code>");
			section.content = isCode ? processCodeBlocks(section.content) 
			                         : processMarkdown(section.content);
		}

		if (prevComments.length > 0)
		{
			if(ditto) {c = prevComments[$ - 1];}
			else      {prevComments[$ - 1] = c;}
		}


		writeComment(dst, c, functionBody);

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
			writeSection(dst,
			{
				dst.put("<h2>Example</h2>\n");
				auto docApp = appender!string();
				doc[1].unDecorateComment(docApp);
				Comment dc = parseComment(docApp.data, macros);
				writeComment(dst, dc);
				writeCodeBlock(dst, { dst.put(processCode(outdent(doc[0]))); } );
			});
		}
		return rVal;
	}

	final void writeComment(R)(ref R dst, Comment comment, const FunctionBody functionBody = null)
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
				foreach(section; seealsos) { put(section.content); }
				put(`</div>`);
				put(`</div>`);
			}
		}
	}

	final void writeContracts(R)(ref R dst, const InStatement inStatement,
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
					if (outStatement !is null) { dst.put("\n"); }
				}
				if (outStatement !is null)
					formatter.format(outStatement);
			});
		});
	}

	import item;
	final void writeItemEntry(R)(ref R dst, ref Item item)
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
		// By default, just print the name of the item.
		else { writeName(); }
		dst.put(`</td>`);

		dst.put(`<td>`);
		if (item.type !is null)
		{
			writeCodeBlock(dst, { dst.put(item.type); });
		}
		dst.put(`</td><td>%s</td></tr>`.format(item.summary));
	}

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

protected:
	const(Config)* config;
	string[string] macros;
	File searchIndex;
	TocItem[] tocItems;
	string[] tocAdditionals;

	/** Stack of associative arrays.
	 *
	 * Each level contains documentation page files of members of the symbol at that
	 * level; e.g. symbolFileStack[0] contains the module documentation file,
	 * symbolFileStack[1] doc pages of the module's child classes, and so on.
	 *
	 * Note that symbolFileStack levels correspond to symbol stack levels. Depending
	 * on the HTMLWriter implementation, there may not be files for all levels.
	 *
	 * E.g. with HTMLWriterAggregated, if we have a class called `Class.method.NestedClass`,
	 * when writing `NestedClass` docs symbolFileStack[$ - 3 .. 0] will be something like:
	 * `[["ClassFileName": File(stuff)], [], ["NestedClassFileName": * File(stuff)]]`,
	 * i.e. there will be a stack level for `method` but it will have no contents.
	 *
	 * When popSymbol() is called, all doc page files of that symbol's members are closed
	 * (they must be kept open until then to ensure overloads are put into the same file).
	 */
	File[string][] symbolFileStack;

	string moduleFileBase_;
	// Path to the HTML file relative to the output directory.
	string moduleLink_;
	// Name length of the module (e.g. 2 for std.stdio)
	size_t moduleNameLength_;
}

/** Get a link to a symbol.
 *
 * Note: this does not check if the symbol exists; calling symbolLink() with a SymbolStack
 * of a nonexistent symbol will result in a link to the deepest existing parent symbol.
 *
 * Params: nameStack = SymbolStack returned by SymbolDatabase.symbolStack(),
 *                     describing a fully qualified symbol name.
 *
 * Returns: Link to the file with documentation for the symbol.
 */
string symbolLinkAggregated(SymbolStack)(auto ref SymbolStack nameStack)
{
	if(nameStack.empty) { return "UNKNOWN.html"; }
	// Start with the first part of the name so we have something we can buildPath() with.
	string result = nameStack.front.name;
	const firstType = nameStack.front.type;
	bool moduleParent = firstType == SymbolType.Module || firstType == SymbolType.Package;
	nameStack.popFront();

	bool inAnchor = false;
	foreach(name; nameStack) final switch(name.type) with(SymbolType)
	{
		// A new directory is created for each module
		case Module, Package:
			result = result.buildPath(name.name);
			moduleParent = true;
			break;
		// These symbol types have separate files in a module directory.
		case Class, Struct, Interface, Enum, Template:
			// If last name was module/package, the file will be in its
			// directory. Otherwise it will be in the same dir as the parent.
			result = moduleParent ? result.buildPath(name.name)
			                       : result ~ "." ~ name.name;
			moduleParent = false;
			break;
		// These symbol types are documented in their parent symbol's files.
		case Function, Variable, Alias, Value:
			// inAnchor allows us to handle nested functions, which are still
			// documented in the same file as their parent function.
			// E.g. a nested function called entity.EntityManager.foo.bar will
			// have link entity/EntityManager#foo.bar
			result = inAnchor ? result ~ "." ~ name.name
			                  : result ~ ".html#" ~ name.name;
			inAnchor = true;
			break;
	}

	return result ~ (inAnchor ? "" : ".html");
}

/** A HTML writer generating 'aggregated' HTML documentation.
 *
 * Instead of generating a separate file for every variable or function, this only
 * generates files for aggregates (module, struct, class, interface, template, enum),
 * and any non-aggregate symbols are put documented in their aggregate parent's
 * documentation files.
 *
 * E.g. all member functions and data members of a class are documented directly in the
 * file documenting that class instead of in separate files the class documentation would
 * link to like with HTMLWriterSimple.
 *
 * This output results in much less files and lower file size than HTMLWriterSimple, and
 * is arguably easier to use due to less clicking between files.
 */
class HTMLWriterAggregated: HTMLWriterBase!symbolLinkAggregated
{
	alias Super = typeof(super);
	private alias config = Super.config;
	alias writeBreadcrumbs = Super.writeBreadcrumbs;
	alias symbolLink = symbolLinkAggregated;

	this(ref Config config, File searchIndex,
	     TocItem[] tocItems, string[] tocAdditionals)
	{
		super(config, searchIndex, tocItems, tocAdditionals);
	}

	// No separator needed; symbols are already in divs.
	void writeSeparator(R)(ref R dst) {}

	void writeSymbolStart(R)(ref R dst, string link)
	{
		const isAggregate = !link.canFind("#");
		if(!isAggregate)
		{
			// We need a separate anchor so we can style it separately to
			// compensate for fixed breadcrumbs.
			dst.put(`<a class="anchor" id="`);
			dst.put(link.findSplit("#")[2]);
			dst.put(`"></a>`);
		}
		dst.put(isAggregate ? `<div class="aggregate-symbol">` : `<div class="symbol">`);
	}

	void writeSymbolEnd(R)(ref R dst) { dst.put(`</div>`); }

	void writeSymbolDescription(R)(ref R dst, void delegate() descriptionCode)
	{
		dst.put(`<div class="description">`); descriptionCode(); dst.put(`</div>`);
	}

	auto pushSymbol(string[] symbolStackRaw, SymbolDatabase database,
	                ref bool first, ref string itemURL)
	{
		assert(symbolStackRaw.length >= moduleNameLength_,
		       "symbol stack shorter than module name");

		// A symbol-type-aware stack.
		auto symbolStack = database.symbolStack(symbolStackRaw[0 .. moduleNameLength],
		                                        symbolStackRaw[moduleNameLength .. $]);

		// Is this symbol an aggregate?
		// If the last part of the symbol stack (this symbol) is an aggregate, we
		// create a new file for it. Otherwise we write into parent aggregate's file.
		bool isAggregate = false;
		// The deepest level in the symbol stack that is an aggregate symbol.
		// If this symbol is an aggregate, that's symbolStack.walkLength - 1, if
		// this symbol is not an aggregate but its parent is, that's
		// symbolStack.walkLength - 2, etc.
		size_t deepestAggregateLevel = size_t.max;
		size_t nameDepth = 0;
		foreach(name; symbolStack)
		{
			scope(exit) { ++nameDepth; }
			final switch(name.type) with(SymbolType)
			{
				case Module, Package, Class, Struct, Interface, Enum, Template:
					isAggregate = true;
					deepestAggregateLevel = nameDepth;
					break;
				case Function, Variable, Alias, Value:
					isAggregate = false;
					break;
			}
		}

		symbolFileStack.length = symbolFileStack.length + 1;
		addSearchEntry(symbolStack);

		// Name stack of the symbol in the documentation file of which we will
		// write, except the module name part.
		string[] targetSymbolStack;
		size_t fileDepth;
		// If the symbol is not an aggregate, its docs will be written into its
		// closest aggregate parent.
		if(!isAggregate)
		{
			assert(deepestAggregateLevel != size_t.max,
			       "A non-aggregate with no aggregate parent; maybe modules "
			       "are not considered aggregates? (we can't handle that case)");

			// Write into the file for the deepest aggregate parent (+1 is
			// needed to include the name of the parent itself)
			targetSymbolStack =
			    symbolStackRaw[moduleNameLength_ .. deepestAggregateLevel + 1];

			// Going relatively from the end, as the symbolFileStack does not
			// contain items for some or all top-most packages.
			fileDepth = symbolFileStack.length -
			            (symbolStackRaw.length - deepestAggregateLevel) - 1;
		}
		// If the symbol is an aggregate, it will have a file just for itself.
		else
		{
			// The symbol itself is the target.
			targetSymbolStack = symbolStackRaw[moduleNameLength_ .. $];
			// Parent is the second last element of symbolFileStack
			fileDepth = symbolFileStack.length - 2;
			assert(fileDepth < symbolFileStack.length,
			       "integer overflow (symbolFileStack should have length >= 2 here): %s %s"
			       .format(fileDepth, symbolFileStack.length));
		}

		// Path relative to output directory
		string docFileName = targetSymbolStack.empty
			? moduleFileBase_ ~ ".html"
			: moduleFileBase_.buildPath(targetSymbolStack.joiner(".").array.to!string) ~ ".html";
		itemURL = symbolLink(symbolStack);

		// Look for a file if it already exists, create if it does not.
		File* p = docFileName in symbolFileStack[fileDepth];
		first = p is null;
		if (first)
		{
			auto f = File(config.outputDirectory.buildPath(docFileName), "w");
			symbolFileStack[fileDepth][docFileName] = f;
			return f.lockingTextWriter;
		}
		else { return p.lockingTextWriter; }
	}
}


/** symbolLink implementation for HTMLWriterSimple.
 *
 * See_Also: symbolLinkAggregated
 */
string symbolLinkSimple(SymbolStack)(auto ref SymbolStack nameStack)
{
	if(nameStack.empty) { return "UNKNOWN.html"; }
	// Start with the first part of the name so we have something we can buildPath() with.
	string result = nameStack.front.name;
	const firstType = nameStack.front.type;
	bool moduleParent = firstType == SymbolType.Module || firstType == SymbolType.Package;
	nameStack.popFront();

	foreach(name; nameStack) final switch(name.type) with(SymbolType)
	{
		// A new directory is created for each module
		case Module, Package:
			result = result.buildPath(name.name);
			moduleParent = true;
			break;
		// These symbol types have separate files in a module directory.
		case Class, Struct, Interface, Enum, Function, Variable, Alias, Template:
			// If last name was module/package, the file will be in its
			// directory. Otherwise it will be in the same dir as the parent.
			result = moduleParent ? result.buildPath(name.name)
			                       : result ~ "." ~ name.name;
			moduleParent = false;
			break;
		// Enum members are documented in their enums.
		case Value: result = result; break;
	}

	return result ~ ".html";
}

class HTMLWriterSimple: HTMLWriterBase!symbolLinkSimple
{
	alias Super = typeof(super);
	private alias config = Super.config;
	alias writeBreadcrumbs = Super.writeBreadcrumbs;
	alias symbolLink = symbolLinkSimple;

	this(ref Config config, File searchIndex,
	     TocItem[] tocItems, string[] tocAdditionals)
	{
		super(config, searchIndex, tocItems, tocAdditionals);
	}

	/// Write a separator (e.g. between two overloads of a function)
	void writeSeparator(R)(ref R dst) { dst.put("<hr/>"); }

	// Do nothing. No divs needed as every symbol is in a separate file.
	void writeSymbolStart(R)(ref R dst, string link) { }
	void writeSymbolEnd(R)(ref R dst) { }

	void writeSymbolDescription(R)(ref R dst, void delegate() descriptionCode)
	{
		descriptionCode();
	}

	auto pushSymbol(string[] symbolStack, SymbolDatabase database,
	                ref bool first, ref string itemURL)
	{
		symbolFileStack.length = symbolFileStack.length + 1;

		assert(symbolStack.length >= moduleNameLength_,
		       "symbol stack shorter than module name");

		auto tail = symbolStack[moduleNameLength_ .. $];
		// Path relative to output directory
		const docFileName = tail.empty
			? moduleFileBase_ ~ ".html"
			: moduleFileBase_.buildPath(tail.joiner(".").array.to!string) ~ ".html";

		addSearchEntry(database.symbolStack(symbolStack[0 .. moduleNameLength],
		                                    symbolStack[moduleNameLength .. $]));

		// The second last element of symbolFileStack
		immutable size_t i = symbolFileStack.length - 2;
		assert (i < symbolFileStack.length, "%s %s".format(i, symbolFileStack.length));
		auto p = docFileName in symbolFileStack[i];
		first = p is null;
		itemURL = docFileName;
		if (first)
		{
			first = true;
			auto f = File(config.outputDirectory.buildPath(docFileName), "w");
			symbolFileStack[i][docFileName] = f;
			return f.lockingTextWriter;
		}
		else
			return p.lockingTextWriter;
	}
}


enum HTML_END = `
</div>
<footer>
Generated with <a href="https://github.com/kiith-sa/harbored-mod">harbored-mod</a>
</footer>
</div>
</body>
</html>`;

private:

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
