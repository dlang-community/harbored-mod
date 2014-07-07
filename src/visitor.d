/**
 * D Documentation Generator
 * Copyright: © 2014 Economic Modeling Specialists, Intl.
 * Authors: Brian Schott
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt Boost License 1.0)
 */
module visitor;

import std.stdio;
import std.file;
import std.d.formatter;
import std.d.lexer;
import std.d.ast;
import ddoc.comments;
import std.algorithm;

enum HTML_END = `
</div>
<script>hljs.initHighlightingOnLoad();</script>
</body>
</html>`;

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
<body>`);
}

struct Item
{
	string url;
	string name;
	string summary;
	string type;

	void write(File f)
	{
		f.write(`<tr><td>`);
		if (url == "#")
			f.write(name, `</td>`);
		else
			f.write(`<a href="`, stripLeadingDirectory(url), `">`, name, `</a></td>`);
		if (type is null)
			f.write(`<td></td><td>`, summary ,`</td></tr>`);
		else
			f.write(`<td><pre><code>`, type, `</code></pre></td><td>`, summary ,`</td></tr>`);
	}
}

struct Members
{
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
		if (aliases.length > 0)
			write(f, aliases, "Aliases");
		if (classes.length > 0)
			write(f, classes, "Classes");
		if (enums.length > 0)
			write(f, enums, "Enums");
		if (functions.length > 0)
			write(f, functions, "Functions");
		if (interfaces.length > 0)
			write(f, interfaces, "Interfaces");
		if (structs.length > 0)
			write(f, structs, "Structs");
		if (templates.length > 0)
			write(f, templates, "Templates");
		if (values.length > 0)
			write(f, values, "Values");
		if (variables.length > 0)
			write(f, variables, "Variables");
		f.writeln(`</div>`);
	}

	void write(File f, Item[] items, string name)
	{
		f.writeln(`<h3>`, name, `</h3>`);
		f.writeln(`<table>`);
//		f.writeln(`<thead><tr><th>Name</th><th>Summary</th></tr></thead>`);
		foreach (i; items)
			i.write(f);
		f.writeln(`</table>`);
	}
}

///
class DocVisitor : ASTVisitor
{
	import std.path;
	this(string outputDirectory, string[string] macros, File searchIndex)
	{
		this.outputDirectory = outputDirectory;
		this.macros = macros;
		this.searchIndex = searchIndex;
	}

	override void visit(const Module mod)
	{
		import std.algorithm;
		import std.path;
		import std.range;
		import std.file;
		import std.conv;

		if (mod.moduleDeclaration is null)
			return;
		stack = cast(string[]) mod.moduleDeclaration.moduleName.identifiers.map!(a => a.text).array;
		baseLength = stack.length;
		moduleFileBase = chain(only(outputDirectory), stack).buildPath;
		if (!exists(moduleFileBase.dirName()))
			moduleFileBase.dirName().mkdirRecurse();
		File output = File(moduleFileBase ~ ".html", "w");

		location = output.name;
		moduleName = to!string(stack.join("."));
		writeHeader(output, moduleName, baseLength - 1);

		writeBreadcrumbs(output);

		prevComments.length = 1;

		if (mod.moduleDeclaration.comment !is null)
			readAndWriteComment(output, mod.moduleDeclaration.comment, macros,
				prevComments);

		memberStack.length = 1;

		mod.accept(this);

		memberStack[$ - 1].write(output);

		output.writeln(HTML_END);
		output.close();

	}

	void visitAggregateDeclaration(A, string name)(const A ad)
	{
		if (ad.comment is null)
			return;
		File f = pushSymbol(ad.name.text);
		scope(exit) popSymbol(f);
		writeBreadcrumbs(f);

		string summary = readAndWriteComment(f, ad.comment, macros, prevComments);
		mixin(`memberStack[$ - 2].` ~ name ~ ` ~= Item(findSplitAfter(f.name, "/")[1], ad.name.text, summary);`);
		prevComments.length = prevComments.length + 1;
		ad.accept(this);
		prevComments = prevComments[0 .. $ - 1];
		memberStack[$ - 1].write(f);
	}

	override void visit(const EnumDeclaration ed)
	{
		visitAggregateDeclaration!(EnumDeclaration, "enums")(ed);
	}

	override void visit(const EnumMember member)
	{
		if (member.comment is null)
			return;
		File blackHole = File("/dev/null", "w");
		string summary = readAndWriteComment(blackHole, member.comment, macros,
			prevComments);
		memberStack[$ - 1].values ~= Item("#", member.name.text, summary);
	}

	override void visit(const ClassDeclaration cd)
	{
		if (cd.comment is null)
			return;
		File f = pushSymbol(cd.name.text);
		scope(exit) popSymbol(f);
		writeBreadcrumbs(f);
		f.write(`<pre><code>`);
		f.write("class ", cd.name.text);
		auto writer = f.lockingTextWriter();
		auto formatter = new Formatter!(File.LockingTextWriter)(writer);
		scope(exit) formatter.sink = File.LockingTextWriter.init;
		if (cd.baseClassList !is null)
			formatter.format(cd.baseClassList);
		if (cd.templateParameters !is null)
			formatter.format(cd.templateParameters);
		if (cd.constraint !is null)
			formatter.format(cd.constraint);
		f.writeln(`</code></pre>`);
		string summary = readAndWriteComment(f, cd.comment, macros, prevComments);
		memberStack[$ - 2].classes ~= Item(findSplitAfter(f.name, "/")[1],
			cd.name.text, summary);
		prevComments.length = prevComments.length + 1;
		cd.accept(this);
		prevComments = prevComments[0 .. $ - 1];
		memberStack[$ - 1].write(f);
	}

	override void visit(const TemplateDeclaration td)
	{
		if (td.comment is null)
			return;
		File f = pushSymbol(td.name.text);
		scope(exit) popSymbol(f);
		writeBreadcrumbs(f);
		f.write(`<pre><code>`);
		f.write("template ", td.name.text);
		auto writer = f.lockingTextWriter();
		auto formatter = new Formatter!(File.LockingTextWriter)(writer);
		scope(exit) formatter.sink = File.LockingTextWriter.init;
		if (td.templateParameters !is null)
			formatter.format(td.templateParameters);
		if (td.constraint)
			formatter.format(td.constraint);
		f.writeln(`</code></pre>`);
		string summary = readAndWriteComment(f, td.comment, macros, prevComments);
		memberStack[$ - 2].templates ~= Item(findSplitAfter(f.name, "/")[1],
			td.name.text, summary);
		prevComments.length = prevComments.length + 1;
		td.accept(this);
		prevComments = prevComments[0 .. $ - 1];
		memberStack[$ - 1].write(f);
	}

	override void visit(const StructDeclaration sd)
	{
		if (sd.comment is null)
			return;
		File f = pushSymbol(sd.name.text);
		scope(exit) popSymbol(f);
		writeBreadcrumbs(f);
		f.write(`<pre><code>`);
		f.write("struct ", sd.name.text);
		auto writer = f.lockingTextWriter();
		auto formatter = new Formatter!(File.LockingTextWriter)(writer);
		scope(exit) formatter.sink = File.LockingTextWriter.init;
		if (sd.templateParameters)
			formatter.format(sd.templateParameters);
		if (sd.constraint)
			formatter.format(sd.constraint);
		f.writeln(`</code></pre>`);
		string summary = readAndWriteComment(f, sd.comment, macros, prevComments);
		memberStack[$ - 2].structs ~= Item(findSplitAfter(f.name, "/")[1],
			sd.name.text, summary);
		prevComments.length = prevComments.length + 1;
		sd.accept(this);
		prevComments = prevComments[0 .. $ - 1];
		memberStack[$ - 1].write(f);
	}

	override void visit(const InterfaceDeclaration id)
	{
		if (id.comment is null)
			return;
		File f = pushSymbol(id.name.text);
		scope(exit) popSymbol(f);
		writeBreadcrumbs(f);
		f.write(`<pre><code>`);
		f.write("interface ", id.name.text);
		auto writer = f.lockingTextWriter();
		auto formatter = new Formatter!(File.LockingTextWriter)(writer);
		scope(exit) formatter.sink = File.LockingTextWriter.init;
		if (id.baseClassList !is null)
			formatter.format(id.baseClassList);
		if (id.templateParameters !is null)
			formatter.format(id.templateParameters);
		if (id.constraint !is null)
			formatter.format(id.constraint);
		f.writeln(`</code></pre>`);
		string summary = readAndWriteComment(f, id.comment, macros, prevComments);
		memberStack[$ - 2].interfaces ~= Item(findSplitAfter(f.name, "/")[1],
			id.name.text, summary);
		prevComments.length = prevComments.length + 1;
		id.accept(this);
		prevComments = prevComments[0 .. $ - 1];
		memberStack[$ - 1].write(f);
	}

	override void visit(const AliasDeclaration ad)
	{
		if (ad.comment is null)
			return;
		if (ad.name != tok!"")
		{
			File f = pushSymbol(ad.name.text);
			scope(exit) popSymbol(f);
			writeBreadcrumbs(f);
			string type = writeType(f, ad.name.text, ad.type);
			string summary = readAndWriteComment(f, ad.comment, macros, prevComments);
			memberStack[$ - 2].aliases ~= Item(findSplitAfter(f.name, "/")[1],
				ad.name.text, summary, type);
		}
		else foreach (initializer; ad.initializers)
		{
			File f = pushSymbol(initializer.name.text);
			scope(exit) popSymbol(f);
			writeBreadcrumbs(f);
			string type = writeType(f, initializer.name.text, initializer.type);
			string summary = readAndWriteComment(f, ad.comment, macros, prevComments);
			memberStack[$ - 2].aliases ~= Item(findSplitAfter(f.name, "/")[1],
				initializer.name.text, summary, type);
		}
	}

	override void visit(const VariableDeclaration vd)
	{
		foreach (const Declarator dec; vd.declarators)
		{
			if (vd.comment is null && dec.comment is null)
				continue;
			File f = pushSymbol(dec.name.text);
			scope(exit) popSymbol(f);
			writeBreadcrumbs(f);
			string summary = readAndWriteComment(f,
				dec.comment is null ? vd.comment : dec.comment, macros,
				prevComments);
			memberStack[$ - 2].variables ~= Item(findSplitAfter(f.name, "/")[1],
				dec.name.text, summary, formatNode(vd.type));
		}
		if (vd.comment !is null && vd.autoDeclaration !is null) foreach (ident; vd.autoDeclaration.identifiers)
		{
			File f = pushSymbol(ident.text);
			scope(exit) popSymbol(f);
			writeBreadcrumbs(f);
			string summary = readAndWriteComment(f, vd.comment, macros, prevComments);
			if (vd.storageClass.token == tok!"enum")
				memberStack[$ - 2].enums ~= Item(findSplitAfter(f.name, "/")[1],
					ident.text, summary, str(vd.storageClass.token.type));
			else
				memberStack[$ - 2].variables ~= Item(findSplitAfter(f.name, "/")[1],
					ident.text, summary, str(vd.storageClass.token.type));
		}
	}

	override void visit(const FunctionDeclaration fd)
	{
		if (fd.comment is null)
			return;
		File f = pushSymbol(fd.name.text, fd.name.index);
		scope(exit) popSymbol(f);
		writeBreadcrumbs(f);
		auto writer = f.lockingTextWriter();
		auto formatter = new Formatter!(File.LockingTextWriter)(writer);
		scope(exit) formatter.sink = File.LockingTextWriter.init;
		writer.put(`<pre><code>`);
		if (fd.returnType)
		{
			formatter.format(fd.returnType);
			writer.put(" ");
		}
		else
		{
			if (fd.hasAuto)
				writer.put("auto ");
			if (fd.hasRef)
				writer.put("ref ");
		}
		formatter.format(fd.name);
		if (fd.templateParameters !is null)
			formatter.format(fd.templateParameters);
		if (fd.parameters !is null)
			formatter.format(fd.parameters);
		if (fd.constraint)
		{
			writer.put(" ");
			formatter.format(fd.constraint);
		}
		writer.put("\n</code></pre>");
		string summary = readAndWriteComment(f, fd.comment, macros, prevComments);
		memberStack[$ - 2].functions ~= Item(findSplitAfter(f.name, "/")[1], fd.name.text, summary);
		prevComments.length = prevComments.length + 1;
		fd.accept(this);
		prevComments = prevComments[0 .. $ - 1];

	}

	alias visit = ASTVisitor.visit;

	string moduleName;
	string location;

private:

	static string formatNode(T)(const T t)
	{
		import std.array;
		auto writer = appender!string();
		auto formatter = new Formatter!(typeof(writer))(writer);
		formatter.format(t);
		return writer.data;
	}

	static string writeType(File f, string name, const Type t)
	{
		import std.array;
		if (t is null)
			return null;
		f.write(`<pre><code>`);
		f.write("alias ", name, " = ");
		string formatted = formatNode(t);
		f.write(formatted);
		f.writeln(`</code></pre>`);
		return formatted;
	}

	void writeBreadcrumbs(File f)
	{
		import std.array;
		import std.conv;
		import std.range;
		f.writeln(`<iframe seamless="seamless" src="toc.html"></iframe>`);
		f.writeln(`<div class="breadcrumbs">`);
		f.writeln(`<table id="results"></table>`);
		f.writeln(`<input type="search" id="search" placeholder="Search" onkeyup="searchSubmit(this.value, event)"/>`);
		foreach (i; 0 .. stack.length)
		{
			if (i + 1 < stack.length)
			{
				if (i >= baseLength - 1)
				{
					string link = buildPath(chain(stack[0 .. baseLength - 1],
						only(stack[baseLength - 1.. $ - 1].join("."))));
//					writeln(link, ".html");
					f.write(`<a href="`, link, `.html">`);
					f.write(stack[i]);
					f.write(`</a>.`);
				}
				else
				{
					f.write(stack[i]);
					f.write(".");
				}
			}
			else
				f.write(stack[i]);
		}
		f.writeln(`</div>`);
		f.writeln(`<div class="content">`);
	}

	File pushSymbol(string name, size_t index = 0)
	{
		import std.array;
		import std.string;
		stack ~= name;
		memberStack.length = memberStack.length + 1;
		string classDocFileName = index == 0 ?
			format("%s.%s.html", moduleFileBase, join(stack[baseLength .. $], ".").array)
			: format("%s.%s%d.html", moduleFileBase, join(stack[baseLength .. $], ".").array, index);
		string path = (classDocFileName.length > 2 && classDocFileName[0 .. 2] == "./")
				? stripLeadingDirectory(classDocFileName[2 .. $])
				: classDocFileName;
		searchIndex.writefln(`{"%s" : "%s"},`, join(stack, ".").array, path);
		auto f = File(classDocFileName, "w");
		writeHeader(f, name, baseLength - 1);
		return f;
	}

	void popSymbol(File f)
	{
		f.writeln(HTML_END);
		stack = stack[0 .. $ - 1];
		memberStack = memberStack[0 .. $ - 1];
	}

	Comment[] prevComments;
	size_t baseLength;
	string outputDirectory;
	string moduleFileBase;
	string[] stack;
	string[string] macros;
	Members[] memberStack;
	File searchIndex;
}

string stripLeadingDirectory(string s)
{
	import std.algorithm;
	return findSplitAfter(s, "/")[1];
}

/**
 * Returns: the summary
 */
string readAndWriteComment(File f, string comment, ref string[string] macros,
	Comment[] prevComments = null)
{
	import std.d.lexer;
	import std.array;
	auto app = appender!string();
	comment.unDecorateComment(app);
//		writeln(comment, " undecorated to ", app.data);
	Comment c = parseComment(app.data, macros);
	if (c.isDitto)
		c = prevComments[$ - 1];
	else if (prevComments.length > 0)
		prevComments[$ - 1] = c;
	writeComment(f, c);
	if (c.sections.length && c.sections[0].name == "Summary")
		return c.sections[0].content;
	foreach (section; c.sections)
	{
		if (section.name == "Returns")
			return "Returns: " ~ section.content;
	}
	return "";
}

void writeComment(File f, Comment comment)
{
//		writeln("writeComment: ", comment.sections.length, " sections.");
	foreach (section; comment.sections)
	{
		if (section.name == "Macros")
			continue;
		f.writeln(`<div class="section">`);
		if (section.name != "Summary" && section.name != "Description")
		{
			f.write("<h3>");
			f.write(section.name == "See_also" ? "See Also" : section.name);
			f.writeln("</h3>");
		}
		if (section.name == "Params")
		{
			f.writeln(`<table class="params">`);
			foreach (k, v; section.mapping)
			{
				f.write(`<tr class="param"><td class="paramName">`);
				f.write(k);
				f.write(`</td><td class="paramDoc">`);
				f.write(v);
				f.writeln("</td></tr>");
			}
			f.write("</table>");
		}
		else
		{
//				f.writeln("<p>");
			f.writeln(section.content);
//				f.writeln("</p>");
		}
		f.writeln(`</div>`);
	}
}
