/**
 * D Documentation Generator
 * Copyright: © 2014 Economic Modeling Specialists, Intl.
 * Authors: Brian Schott
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt Boost License 1.0)
 */
module visitor;

import config;
import ddoc.comments;
import formatter;
import std.algorithm;
import std.array: appender, empty, array;
import std.d.ast;
import std.d.formatter;
import std.d.lexer;
import std.file;
import std.path;
import std.stdio;
import std.typecons;
import tocbuilder: TocItem;
import unittest_preprocessor;


/**
 * Generates documentation for a module.
 */
class DocVisitor : ASTVisitor
{
	/**
	 * Params:
	 *     config = Configuration data, including macros and the output directory.
	 *     searchIndex = A file where the search information will be written
	 *     unitTestMapping = The mapping of declaration addresses to their
	 *         documentation unittests
	 *     fileBytes = The source code of the module as a byte array.
	 *     tocItems = Items of the table of contents to write into each
	 *                documentation file.
	 *     tocAdditional = Additional content for the table of contents sidebar.
	 */
	this(ref const Config config, string[string] macros, File searchIndex,
		TestRange[][size_t] unitTestMapping, const(ubyte[]) fileBytes,
		TocItem[] tocItems, string tocAdditional)
	{
		this.macros = macros;
		this.config = &config;
		this.searchIndex = searchIndex;
		this.unitTestMapping = unitTestMapping;
		this.fileBytes = fileBytes;
		this.tocItems = tocItems;
		this.tocAdditional = tocAdditional;
	}

	/**
	 * Same as visit(const Module), but only determines the file (location) of the
	 * documentation, link to that file and module name, without actually writing the
	 * documentation.
	 *
	 * Returns: true if the module location was successfully determined, false if
	 *          there is no module declaration or the module is excluded from
	 *          generated documentation by the user.
	 */
	bool moduleInitLocation(const Module mod)
	{
		import std.range : chain, iota, join, only;
		import std.file : mkdirRecurse;
		import std.conv : to;

		if (mod.moduleDeclaration is null)
			return false;
		pushAttributes();
		stack = cast(string[]) mod.moduleDeclaration.moduleName.identifiers.map!(a => a.text).array;

		foreach(exclude; config.excludes)
		{
			// If module name is pkg1.pkg2.mod, we first check
			// "pkg1", then "pkg1.pkg2", then "pkg1.pkg2.mod"
			// i.e. we only check for full package/module names.
			if(iota(stack.length + 1).map!(l => stack[0 .. l].join(".")).canFind(exclude))
			{
				writeln("Excluded module ", stack.join("."));
				return false;
			}
		}

		baseLength = stack.length;
		moduleFileBase = stack.buildPath;
		link = moduleFileBase ~ ".html";


		const moduleFileBaseAbs = config.outputDirectory.buildPath(moduleFileBase);
		if (!exists(moduleFileBaseAbs))
			moduleFileBaseAbs.mkdirRecurse();
		const outputName = moduleFileBaseAbs ~ ".html";

		location = outputName;
		moduleName = to!string(stack.join("."));

		return true;
	}

	override void visit(const Module mod)
	{
		if(!moduleInitLocation(mod))
		{
			return;
		}

		File output = File(location, "w");
		writeHeader(output, moduleName, baseLength - 1);
		writeTOC(output, tocItems, tocAdditional);
		writeBreadcrumbs(output);

		prevComments.length = 1;

		if (mod.moduleDeclaration.comment !is null)
			readAndWriteComment(output, mod.moduleDeclaration.comment, config, macros,
				prevComments, null, getUnittestDocTuple(mod.moduleDeclaration));

		memberStack.length = 1;

		mod.accept(this);

		memberStack[$ - 1].write(output);

		output.writeln(HTML_END);
		output.close();
	}

	override void visit(const EnumDeclaration ed)
	{
		enum formattingCode = q{
		f.write("enum ", ad.name.text);
		if (ad.type !is null)
		{
			f.write(" : ");
			formatter.format(ad.type);
		}
		};
		visitAggregateDeclaration!(formattingCode, "enums")(ed);
	}

	override void visit(const EnumMember member)
	{
		if (member.comment is null)
			return;
		string summary = readAndWriteComment(File.init, member.comment, config, macros,
			prevComments, null, getUnittestDocTuple(member));
		memberStack[$ - 1].values ~= Item("#", member.name.text, summary);
	}

	override void visit(const ClassDeclaration cd)
	{
		enum formattingCode = q{
		f.write("class ", ad.name.text);
		if (ad.baseClassList !is null)
			formatter.format(ad.baseClassList);
		if (ad.templateParameters !is null)
			formatter.format(ad.templateParameters);
		if (ad.constraint !is null)
			formatter.format(ad.constraint);
		};
		visitAggregateDeclaration!(formattingCode, "classes")(cd);
	}

	override void visit(const TemplateDeclaration td)
	{
		enum formattingCode = q{
		f.write("template ", ad.name.text);
		if (ad.templateParameters !is null)
			formatter.format(ad.templateParameters);
		if (ad.constraint)
			formatter.format(ad.constraint);
		};
		visitAggregateDeclaration!(formattingCode, "templates")(td);
	}

	override void visit(const StructDeclaration sd)
	{
		enum formattingCode = q{
		f.write("struct ", ad.name.text);
		if (ad.templateParameters)
			formatter.format(ad.templateParameters);
		if (ad.constraint)
			formatter.format(ad.constraint);
		};
		visitAggregateDeclaration!(formattingCode, "structs")(sd);
	}

	override void visit(const InterfaceDeclaration id)
	{
		enum formattingCode = q{
		f.write("interface ", ad.name.text);
		if (ad.templateParameters !is null)
			formatter.format(ad.templateParameters);
		if (ad.baseClassList !is null)
			formatter.format(ad.baseClassList);
		if (ad.constraint !is null)
			formatter.format(ad.constraint);
		};
		visitAggregateDeclaration!(formattingCode, "interfaces")(id);
	}

	override void visit(const AliasDeclaration ad)
	{
		import std.path : dirSeparator;
		if (ad.comment is null)
			return;
		bool first;
		if (ad.identifierList !is null)
		{
			foreach (name; ad.identifierList.identifiers)
			{
				auto fileWithLink = pushSymbol(name.text, first);
				File f = fileWithLink[0];
				string link = fileWithLink[1];

				scope(exit) popSymbol(f);
				writeBreadcrumbs(f);
				string type = writeAliasType(f, name.text, ad.type);
				string summary = readAndWriteComment(f, ad.comment, config, macros, prevComments);
				memberStack[$ - 2].aliases ~= Item(link, name.text, summary, type);
			}
		}
		else foreach (initializer; ad.initializers)
		{
			auto fileWithLink = pushSymbol(initializer.name.text, first);
			File f = fileWithLink[0];
			string link = fileWithLink[1];

			scope(exit) popSymbol(f);
			writeBreadcrumbs(f);
			string type = writeAliasType(f, initializer.name.text, initializer.type);
			string summary = readAndWriteComment(f, ad.comment, config, macros, prevComments);
			memberStack[$ - 2].aliases ~= Item(link, initializer.name.text, summary, type);
		}
	}

	override void visit(const VariableDeclaration vd)
	{
		bool first;
		foreach (const Declarator dec; vd.declarators)
		{
			if (vd.comment is null && dec.comment is null)
				continue;
			auto fileWithLink = pushSymbol(dec.name.text, first);
			File f = fileWithLink[0];
			string link = fileWithLink[1];

			scope(exit) popSymbol(f);
			writeBreadcrumbs(f);
			string summary = readAndWriteComment(f,
				dec.comment is null ? vd.comment : dec.comment, config, macros,
				prevComments);
			memberStack[$ - 2].variables ~= Item(link, dec.name.text, summary, formatNode(vd.type));
		}
		if (vd.comment !is null && vd.autoDeclaration !is null) foreach (ident; vd.autoDeclaration.identifiers)
		{
			auto fileWithLink = pushSymbol(ident.text, first);
			File f = fileWithLink[0];
			string link = fileWithLink[1];

			scope(exit) popSymbol(f);
			writeBreadcrumbs(f);
			string summary = readAndWriteComment(f, vd.comment, config, macros, prevComments);
			// TODO this was hastily updated to get harbored-mod to compile
			// after a libdparse update. Revisit and validate/fix any errors.
			string[] storageClasses;
			foreach(stor; vd.storageClasses)
			{
				storageClasses ~= str(stor.token.type);
			}
			auto i = Item(link, ident.text, summary, storageClasses.canFind("enum") ? null : "auto");
			if (storageClasses.canFind("enum"))
				memberStack[$ - 2].enums ~= i;
			else
				memberStack[$ - 2].variables ~= i;

			// string storageClass;
			// foreach (attr; vd.attributes)
			// {
			// 	if (attr.storageClass !is null)
			// 		storageClass = str(attr.storageClass.token.type);
			// }
			// auto i = Item(name, ident.text,
			// 	summary, storageClass == "enum" ? null : "auto");
			// if (storageClass == "enum")
			// 	memberStack[$ - 2].enums ~= i;
			// else
			// 	memberStack[$ - 2].variables ~= i;
		}
	}

	override void visit(const StructBody sb)
	{
		pushAttributes();
		sb.accept(this);
		popAttributes();
	}

	override void visit(const BlockStatement bs)
	{
		pushAttributes();
		bs.accept(this);
		popAttributes();
	}

	override void visit(const Declaration dec)
	{
		attributes[$ - 1] ~= dec.attributes;
		dec.accept(this);
		if (dec.attributeDeclaration is null)
			attributes[$ - 1] = attributes[$ - 1][0 .. $ - dec.attributes.length];
	}

	override void visit(const AttributeDeclaration dec)
	{
		attributes[$ - 1] ~= dec.attribute;
	}

	override void visit(const Constructor cons)
	{
		if (cons.comment is null)
			return;
		bool first;
		auto fileWithLink = pushSymbol("this", first);
		File f = fileWithLink[0];
		string link = fileWithLink[1];


		writeFnDocumentation(f, link, cons, attributes[$ - 1], first);
	}

	override void visit(const FunctionDeclaration fd)
	{
		if (fd.comment is null)
			return;
		bool first;
		auto fileWithLink = pushSymbol(fd.name.text, first);
		File f = fileWithLink[0];
		string link = fileWithLink[1];

		writeFnDocumentation(f, link, fd, attributes[$ - 1], first);
	}

	alias visit = ASTVisitor.visit;

	/// The module name in "package.package.module" format.
	string moduleName;

	/// The path to the HTML file that was generated for the module being
	/// processed.
	string location;

	/// Path to the HTML file relative to the output directory.
	string link;


private:

	void visitAggregateDeclaration(string formattingCode, string name, A)(const A ad)
	{
		bool first;
		if (ad.comment is null)
			return;

		auto fileWithLink = pushSymbol(ad.name.text, first);
		File f = fileWithLink[0];
		string link = fileWithLink[1];

		if (first)
			writeBreadcrumbs(f);
		else
			f.writeln("<hr/>");
		{
			auto writer = f.lockingTextWriter();
			writer.put(`<pre><code>`);
			auto formatter = new HarboredFormatter!(File.LockingTextWriter)(writer);
			scope(exit) formatter.sink = File.LockingTextWriter.init;
			writeAttributes(formatter, writer, attributes[$ - 1]);
			mixin(formattingCode);
			writer.put("\n</code></pre>");
		}
		string summary = readAndWriteComment(f, ad.comment, config, macros, prevComments,
			null, getUnittestDocTuple(ad));
		mixin(`memberStack[$ - 2].` ~ name ~ ` ~= Item(link, ad.name.text, summary);`);
		prevComments.length = prevComments.length + 1;
		ad.accept(this);
		prevComments = prevComments[0 .. $ - 1];
		memberStack[$ - 1].write(f);

		stack = stack[0 .. $ - 1];
		memberStack = memberStack[0 .. $ - 1];
	}

	/**
	 * Params:
	 *     t = The declaration.
	 * Returns: An array of tuples where the first item is the contents of the
	 *     unittest block and the second item is the doc comment for the
	 *     unittest block. This array may be empty.
	 */
	Tuple!(string, string)[] getUnittestDocTuple(T)(const T t)
	{
		immutable size_t index = cast(size_t) (cast(void*) t);
//		writeln("Searching for unittest associated with ", index);
		auto tupArray = index in unitTestMapping;
		if (tupArray is null)
			return [];
//		writeln("Found a doc unit test for ", cast(size_t) &t);
		Tuple!(string, string)[] rVal;
		foreach (tup; *tupArray)
			rVal ~= tuple(cast(string) fileBytes[tup[0] + 2 .. tup[1]], tup[2]);
		return rVal;
	}

	/**
	 *
	 */
	void writeFnDocumentation(Fn)(File f, string fileRelative, Fn fn, const(Attribute)[] attrs, bool first)
	{
		auto writer = f.lockingTextWriter();
		// Stuff above the function doc
		if (first)
			writeBreadcrumbs(f);
		else
			writer.put("<hr/>");

		auto formatter = new HarboredFormatter!(File.LockingTextWriter)(writer);
		scope(exit) formatter.sink = File.LockingTextWriter.init;

		// Function signature start //
		writer.put(`<pre><code>`);
		// Attributes like public, etc.
		writeAttributes(formatter, writer, attrs);
		// Return type and function name, with special case fo constructor
		static if (__traits(hasMember, typeof(fn), "returnType"))
		{
			if (fn.returnType)
			{
				formatter.format(fn.returnType);
				writer.put(" ");
			}
			formatter.format(fn.name);
		}
		else
			writer.put("this");
		// Template params
		if (fn.templateParameters !is null)
			formatter.format(fn.templateParameters);
		// Function params
		if (fn.parameters !is null)
			formatter.format(fn.parameters);
		// Attributes like const, nothrow, etc.
		foreach (a; fn.memberFunctionAttributes)
		{
			writer.put(" ");
			formatter.format(a);
		}
		// Template constraint
		if (fn.constraint)
		{
			writer.put(" ");
			formatter.format(fn.constraint);
		}
		writer.put("\n</code></pre>");
		// Function signature end//

		string summary = readAndWriteComment(f, fn.comment, config, macros,
			prevComments, fn.functionBody, getUnittestDocTuple(fn));
		string fdName;
		static if (__traits(hasMember, typeof(fn), "name"))
			fdName = fn.name.text;
		else
			fdName = "this";
		auto fnItem = Item(fileRelative, fdName, summary, null, fn);
		memberStack[$ - 2].functions ~= fnItem;
		prevComments.length = prevComments.length + 1;
		fn.accept(this);
		prevComments = prevComments[0 .. $ - 1];
		stack = stack[0 .. $ - 1];
		memberStack = memberStack[0 .. $ - 1];
	}

	/**
	 * Writes attributes to the given writer using the given formatter.
	 * Params:
	 *     F = The formatter type
	 *     W = The writer type
	 *     formatter = The formatter instance to use
	 *     writer = The writer that will be output to.
	 *     attrs = The attributes to write.
	 */
	void writeAttributes(F, W)(F formatter, W writer, const(Attribute)[] attrs)
	{
		IdType protection;
		if (attrs is null)
			attrs = attributes[$ - 1];
		if (attributes.length > 0) foreach (a; attrs)
		{
			if (isProtection(a.attribute.type))
				protection = a.attribute.type;
		}
		switch (protection)
		{
		case tok!"private": writer.put("private "); break;
		case tok!"package": writer.put("package "); break;
		default: writer.put("public "); break;
		}
		if (attributes.length > 0) foreach (a; attrs)
		{
			if (!isProtection(a.attribute.type))
			{
				formatter.format(a);
				writer.put(" ");
			}
		}
	}

	/**
	 * Formats an AST node to a string
	 */
	static string formatNode(T)(const T t)
	{
		auto writer = appender!string();
		auto formatter = new HarboredFormatter!(typeof(writer))(writer);
		formatter.format(t);
		return writer.data;
	}

	/**
	 * Writes an alias' type to the given file and returns it.
	 * Params:
	 *     f = The file to write to
	 *     name = the name of the alias
	 *     t = the aliased type
	 * Returns: A string reperesentation of the given type.
	 */
	static string writeAliasType(File f, string name, const Type t)
	{
		if (t is null)
			return null;
		f.write(`<pre><code>`);
		f.write("alias ", name, " = ");
		string formatted = formatNode(t);
		f.write(formatted);
		f.writeln(`</code></pre>`);
		return formatted;
	}

	/**
	 * Writes navigation breadcrumbs in HTML format to the given file.
	 */
	void writeBreadcrumbs(File f)
	{
		import std.array : join;
		import std.conv : to;
		import std.range : chain, only;
		import std.string: format;
		
		string heading;
		scope(exit) { .writeBreadcrumbs(f, heading); }

		assert(baseLength <= stack.length, "stack shallower than the current module?");
		size_t i;
		string link() { return stack[0 .. i + 1].buildPath() ~ ".html"; }

		// Module
		{
			heading ~= "<small>";
			scope(exit) { heading ~= "</small>"; }
			for(; i + 1 < baseLength; ++i)
			{
				heading ~= stack[i] ~ ".";
			}
			// Module link if the module is a parent of the current page.
			if(i + 1 < stack.length)
			{
				heading  ~= `<a href=%s>%s</a>.`.format(link(), stack[i]);
				++i;
			}
			// Just the module name, not a link, if we're at the module page.
			else
			{
				heading ~= stack[i];
				return;
			}
		}

		// Class/Function/etc. in the module
		heading ~= `<span class="highlight">`;
		// The rest of the stack except the last element (parents of current page).
		for(; i + 1 < stack.length; ++i)
		{
			heading  ~= `<a href=%s.html>%s</a>.`.format(link(), stack[i]);
		}
		// The last element (no need to link to the current page).
		heading ~= stack[i];
		heading ~= `</span>`;
	}

	/**
	 * Params:
	 *     name = The symbol's name
	 *     first = True if this is the first time that pushSymbol has been
	 *         called for this name.
	 *     isFunction = True if the symbol being pushed is a function, false
	 *         otherwise.
	 *
	 * Returns: A file that the symbol's documentation should be written to and the
	 *          filename of that file relative to config.outputDirectory.
	 */
	Tuple!(File, string) pushSymbol(string name, ref bool first)
	{
		import std.array : array, join;
		import std.string : format;
		stack ~= name;
		memberStack.length = memberStack.length + 1;
		// Path relative to output directory
		string classDocFileName = moduleFileBase.buildPath(format("%s.html",
			join(stack[baseLength .. $], ".").array));
		searchIndex.writefln(`{"%s" : "%s"},`, join(stack, ".").array, classDocFileName);
		immutable size_t i = memberStack.length - 2;
		assert (i < memberStack.length, "%s %s".format(i, memberStack.length));
		auto p = classDocFileName in memberStack[i].overloadFiles;
		first = p is null;
		if (first)
		{
			first = true;
			auto f = File(config.outputDirectory.buildPath(classDocFileName), "w");
			memberStack[i].overloadFiles[classDocFileName] = f;
			writeHeader(f, name, baseLength);
			writeTOC(f, tocItems, tocAdditional);
			return tuple(f, classDocFileName);
		}
		else
			return tuple(*p, classDocFileName);
	}

	void popSymbol(File f)
	{
		f.writeln(HTML_END);
		stack = stack[0 .. $ - 1];
		memberStack = memberStack[0 .. $ - 1];
	}

	void pushAttributes()
	{
		attributes.length = attributes.length + 1;
	}

	void popAttributes()
	{
		attributes = attributes[0 .. $ - 1];
	}

	const(Attribute)[][] attributes;
	Comment[] prevComments;
	/* Length, or nest level, of the module name.
	 *
	 * `mod` has baseLength, `pkg.mod` has baseLength 2, `pkg.child.mod` has 3, etc.
	 */
	size_t baseLength;
	string moduleFileBase;
	string[] stack;
	string[string] macros;
	Members[] memberStack;
	File searchIndex;
	TestRange[][size_t] unitTestMapping;
	const(ubyte[]) fileBytes;
	TocItem[] tocItems;
	string tocAdditional;
	const(Config)* config;
}

/**
 * Writes HTML header information to the given file.
 * Params:
 *     f = The file to write to
 *     title = The content of the HTML "title" element
 *     depth = The directory depth of the file. This is used for ensuring that
 *         the "base" element is correct so that links resolve properly.
 */
void writeHeader(File f, string title, size_t depth)
{
	f.write(`<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8"/>
<link rel="stylesheet" type="text/css" href="`);
	foreach (i; 0 .. depth)
		f.write("../");
	f.write(`style.css"/><script src="`);
	foreach (i; 0 .. depth)
		f.write("../");
	f.write(`highlight.pack.js"></script>
<title>`);
	f.write(title);
	f.writeln(`</title>`);
	f.write(`<base href="`);
	foreach (i; 0 .. depth)
		f.write("../");
	f.write(`"/>
<script src="search.js"></script>
</head>
<body>
<div class="main">
`);
}

/** Writes the table of contents to specified file.
 *
 * Params:
 *     f             = File to write to.
 *     tocItems      = Items of the table of contents to write.
 *     tocAdditional = Optional additional content.
 */
void writeTOC(File f, TocItem[] tocItems, string tocAdditional)
{
	f.writeln(`<div class="toc">`);
	if(tocAdditional !is null)
	{
		f.writeln(`<div class="toc-additional">`);
		f.writeln(tocAdditional);
		f.writeln(`</div>`);
	}
	f.writeln(`<ul>`);
	foreach (t; tocItems)
		t.write(f);
	f.writeln(`</ul>`);
	f.writeln(`</div>`);
}

/**
  * Writes navigation breadcrumbs in HTML format to the given file.
  *
  * Also starts the "content" <div>; must be called after writeTOC(), before writing
  * main content.
  */
void writeBreadcrumbs(File f, string heading)
{
	f.writeln(`<div class="breadcrumbs">`);
	f.writeln(`<table id="results"></table>`);
	f.writeln(`<a class="home" href=index.html>⌂</a>`);
	f.writeln(`<input type="search" id="search" placeholder="Search" onkeyup="searchSubmit(this.value, event)"/>`);
	f.write(heading);
	f.writeln(`</div>`);
	f.writeln(`<div class="content">`);
}

/**
 * Writes a doc comment to the given file and returns the summary text.
 * Params:
 *     f = The file to write the comment to
 *     comment = The comment to write
 *     macros = Macro definitions used in processing the comment
 *     prevComments = Previously encountered comments. This is used for handling
 *         "ditto" comments. May be null.
 *     functionBody = A function body used for writing contract information. May
 *         be null.
 *     testdocs = Pairs of unittest bodies and unittest doc comments. May be null.
 * Returns: the summary from the given comment
 */
string readAndWriteComment(File f, string comment, const(Config)* config,
	string[string] macros, Comment[] prevComments = null,
	const FunctionBody functionBody = null,
	Tuple!(string, string)[] testDocs = null)
{
	import std.d.lexer : unDecorateComment;
	auto app = appender!string();
	comment.unDecorateComment(app);
//	writeln(comment, " undecorated to ", app.data);

	Comment c = parseComment(app.data, macros);

	// Run sections through markdown.
	foreach(ref section; c.sections) {
		// Do not run code examples through markdown.
		//
		// We could also check for section.name == "Examples" but code blocks can
		// be even outside examples. Alternatively, we could look for *multi-line*
		// <pre>/<code> blocks, or, before parsing comments, for "---" pairs.
		//
		// Alternatively, dmarkdown could be changed to ignore <pre>/<code>
		// blocks.
		import dmarkdown;
		// Ensure param descriptions run through Markdown
		if(section.name == "Params")
		{
			foreach(ref kv; section.mapping)
			{
				kv[1] = filterMarkdown(kv[1], MarkdownFlags.alternateSubheaders);
			}
		}
		if(!section.content.canFind("<pre><code>")) {
			section.content = filterMarkdown(section.content,
			                                 MarkdownFlags.alternateSubheaders);
		}
	}

	if (c.isDitto)
		c = prevComments[$ - 1];
	else if (prevComments.length > 0)
		prevComments[$ - 1] = c;
	if (f != File.init)
		writeComment(f, c, functionBody);

	// Find summary and return value info
	string rVal = "";
	if (c.sections.length && c.sections[0].name == "Summary")
		rVal = c.sections[0].content;
	else
	{
		foreach (section; c.sections)
		{
			if (section.name == "Returns")
				rVal = "Returns: " ~ section.content;
		}
	}
	if (f != File.init && testDocs !is null) foreach (doc; testDocs)
	{
//		writeln("Writing a unittest doc comment");
		import std.string : outdent;
		f.writeln(`<div class="section"><h2>Example</h2>`);
		auto docApp = appender!string();
		doc[1].unDecorateComment(docApp);
		Comment dc = parseComment(docApp.data, macros);
		writeComment(f, dc);
		f.writeln(`<pre><code>`, outdent(doc[0]), `</code></pre>`);
		f.writeln(`</div>`);
	}
	return rVal;
}

private:

void writeComment(File f, Comment comment, const FunctionBody functionBody = null)
{
//		writeln("writeComment: ", comment.sections.length, " sections.");

	size_t i;
	for (i = 0; i < comment.sections.length && (comment.sections[i].name == "Summary"
		|| comment.sections[i].name == "description"); i++)
	{
		f.writeln(`<div class="section">`);
		f.writeln(comment.sections[i].content);
		f.writeln(`</div>`);
	}
	if (functionBody !is null)
		writeContracts(f, functionBody.inStatement, functionBody.outStatement);


	const seealsoNames = ["See_also", "See_Also", "See also", "See Also"];
	foreach (section; comment.sections[i .. $])
	{
		if (seealsoNames.canFind(section.name) || section.name == "Macros")
			continue;

		// Note sections a use different style
		const isNote = section.name == "Note";
		string extraClasses;

		if(isNote)
			extraClasses ~= " note";

		f.writeln(`<div class="section`, extraClasses, `">`);
		if (section.name != "Summary" && section.name != "Description")
		{
			f.write("<h2>");
			f.write(prettySectionName(section.name));
			f.writeln("</h2>");
		}
		if(isNote)
			f.writeln(`<div class="note-content">`);
		if (section.name == "Params")
		{
			f.writeln(`<table class="params">`);
			foreach (kv; section.mapping)
			{
				f.write(`<tr class="param"><td class="paramName">`);
				f.write(kv[0]);
				f.write(`</td><td class="paramDoc">`);
				f.write(kv[1]);
				f.writeln("</td></tr>");
			}
			f.write("</table>");
		}
		else
		{
			f.writeln(section.content);
		}
		if(isNote)
			f.writeln(`</div>`);
		f.writeln(`</div>`);
	}

	// Merge any see also sections into one, and draw it with different style than
	// other sections.
	{
		auto seealsos = comment.sections.filter!(s => seealsoNames.canFind(s.name));
		if(!seealsos.empty)
		{
			f.writeln(`<div class="section seealso">`);
			f.write("<h2>");
			f.write(prettySectionName(seealsos.front.name));
			f.writeln("</h2>");
			f.writeln(`<div class="seealso-content">`);
			foreach(section; seealsos)
			{
				f.writeln(section.content);
			}
			f.writeln(`</div>`);
			f.writeln(`</div>`);
		}
	}

}

void writeContracts(File f, const InStatement inStatement,
	const OutStatement outStatement)
{
	if (inStatement is null && outStatement is null)
		return;
	f.write(`<div class="section"><h2>Contracts</h2><pre><code>`);
	auto formatter = new HarboredFormatter!(File.LockingTextWriter)(f.lockingTextWriter());
	scope(exit) formatter.sink = File.LockingTextWriter.init;
	if (inStatement !is null)
	{
		formatter.format(inStatement);
		if (outStatement !is null)
			f.writeln();
	}
	if (outStatement !is null)
		formatter.format(outStatement);
	f.writeln("</code></pre></div>");
}

string prettySectionName(string sectionName)
{
	switch (sectionName)
	{
	case "See_also", "See_Also", "See also", "See Also": return "See Also:";
	case "Note": return "Note:";
	case "Params": return "Parameters";
	default: return sectionName;
	}
}

enum HTML_END = `
<script>hljs.initHighlightingOnLoad();</script>
</div>
</div>
</body>
</html>`;

struct Item
{
	string url;
	string name;
	string summary;
	string type;

	/// AST node of the item. Only used for functions at the moment.
	const ASTNode node;

	void write(ref File f)
	{
		f.write(`<tr><td>`);
		void writeName()
		{
			if (url == "#")
				f.write(name);
			else
				f.write(`<a href="`, url, `">`, name, `</a>`);
		}

		// TODO print attributes for everything, and move it to separate function/s
		if(cast(FunctionDeclaration) node) with(cast(FunctionDeclaration) node)
		{
			import std.string: join;

			auto writer = appender!(char[])();
			// extremely inefficient, rewrite if too much slowdown
			string format(T)(T attr)
			{
				auto formatter = new HarboredFormatter!(typeof(writer))(writer);
				formatter.format(attr);
				auto str = writer.data.idup;
				writer.clear();
				import std.ascii: isAlpha;
				import std.conv: to;
				auto strSane = str.filter!isAlpha.array.to!string;
				return `<span class="attr-` ~ strSane ~ `">` ~ str ~ `</span>`;
			}

			void writeSpan(C)(string class_, C content)
			{
				f.write(`<span class="`, class_, `">`, content, `</span>`);
			}

			// Above the function name
			if(!attributes.empty)
			{
				f.write(`<span class="extrainfo">`);
				writeSpan("attribs", attributes.map!(a => format(a)).joiner(", "));
				f.write(`</span>`);
			}


			// The actual function name
			writeName();


			// Below the function name
			f.write(`<span class="extrainfo">`);
			if(!memberFunctionAttributes.empty)
			{
				writeSpan("method-attribs",
					memberFunctionAttributes.map!(a => format(a)).joiner(", "));
			}
			// TODO storage classes don't seem to work. libdparse issue?
			if(!storageClasses.empty)
			{
				writeSpan("stor-classes", storageClasses.map!(a => format(a)).joiner(", "));
			}
			f.write(`</span>`);
		}
		else
		{
			writeName();
		}

		f.write(`</td>`);

		f.write(`<td>`);
		if (type !is null)
			f.write(`<pre><code>`, type, `</code></pre>`);
		f.write(`</td><td>`, summary ,`</td></tr>`);
	}
}

struct Members
{
	File[string] overloadFiles;
	Item[] aliases;
	Item[] classes;
	Item[] enums;
	Item[] functions;
	Item[] interfaces;
	Item[] structs;
	Item[] templates;
	Item[] values;
	Item[] variables;

	void write(File f)
	{
		if (aliases.length == 0 && classes.length == 0 && enums.length == 0
			&& functions.length == 0 && interfaces.length == 0
			&& structs.length == 0 && templates.length == 0 && values.length == 0
			&& variables.length == 0)
		{
			return;
		}
		f.writeln(`<div class="section">`);
		if (enums.length > 0)
			write(f, enums, "Enums");
		if (aliases.length > 0)
			write(f, aliases, "Aliases");
		if (variables.length > 0)
			write(f, variables, "Variables");
		if (functions.length > 0)
			write(f, functions, "Functions");
		if (structs.length > 0)
			write(f, structs, "Structs");
		if (interfaces.length > 0)
			write(f, interfaces, "Interfaces");
		if (classes.length > 0)
			write(f, classes, "Classes");
		if (templates.length > 0)
			write(f, templates, "Templates");
		if (values.length > 0)
			write(f, values, "Values");
		f.writeln(`</div>`);
		foreach (f; overloadFiles)
		{
			f.writeln(HTML_END);
			f.close();
		}
	}

private:

	void write(File f, Item[] items, string name)
	{
		f.writeln(`<h2>`, name, `</h2>`);
		f.writeln(`<table>`);
//		f.writeln(`<thead><tr><th>Name</th><th>Summary</th></tr></thead>`);
		foreach (i; items)
			i.write(f);
		f.writeln(`</table>`);
	}
}
