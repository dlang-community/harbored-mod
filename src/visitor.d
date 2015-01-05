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
import std.string: format;
import std.typecons;
import tocbuilder: TocItem;
import unittest_preprocessor;
import writer;


/**
 * Generates documentation for a (single) module.
 */
class DocVisitor(Writer) : ASTVisitor
{
	/**
	 * Params:
	 *     config = Configuration data, including macros and the output directory.
	 *     searchIndex = A file where the search information will be written
	 *     unitTestMapping = The mapping of declaration addresses to their
	 *         documentation unittests
	 *     fileBytes = The source code of the module as a byte array.
	 *     writer = Handles writing into generated files.
	 */
	this(ref const Config config, File searchIndex,
		TestRange[][size_t] unitTestMapping, const(ubyte[]) fileBytes,
		Writer writer)
	{
		this.config = &config;
		this.searchIndex = searchIndex;
		this.unitTestMapping = unitTestMapping;
		this.fileBytes = fileBytes;
		this.writer = writer;
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

		auto fileWriter = output.lockingTextWriter;
		writer.writeHeader(fileWriter, moduleName, baseLength - 1);
		writer.writeTOC(fileWriter, moduleName);
		writeBreadcrumbs(fileWriter);

		prevComments.length = 1;

		const comment = mod.moduleDeclaration.comment;
		if (comment !is null)
		{
			writer.readAndWriteComment(fileWriter, comment, prevComments,
				null, getUnittestDocTuple(mod.moduleDeclaration));
		}

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
		auto dummy = appender!string();
		// No interest in detailed docs for an enum member.
		string summary = writer.readAndWriteComment(dummy, member.comment,
			prevComments, null, getUnittestDocTuple(member));
		memberStack[$ - 1].values ~= Item("#", member.name.text, summary);
	}

	override void visit(const ClassDeclaration cd)
	{
		enum formattingCode = q{
		f.write("class ", ad.name.text);
		if (ad.templateParameters !is null)
			formatter.format(ad.templateParameters);
		if (ad.baseClassList !is null)
			formatter.format(ad.baseClassList);
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

				auto fileWriter = f.lockingTextWriter;
				writeBreadcrumbs(fileWriter);

				string type = writeAliasType(f, name.text, ad.type);
				string summary = writer.readAndWriteComment(fileWriter, ad.comment, prevComments);
				memberStack[$ - 2].aliases ~= Item(link, name.text, summary, type);
			}
		}
		else foreach (initializer; ad.initializers)
		{
			auto fileWithLink = pushSymbol(initializer.name.text, first);
			File f = fileWithLink[0];
			string link = fileWithLink[1];

			scope(exit) popSymbol(f);

			auto fileWriter = f.lockingTextWriter;
			writeBreadcrumbs(fileWriter);

			string type = writeAliasType(f, initializer.name.text, initializer.type);
			string summary = writer.readAndWriteComment(fileWriter, ad.comment, prevComments);
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

			auto fileWriter = f.lockingTextWriter;
			writeBreadcrumbs(fileWriter);

			string summary = writer.readAndWriteComment(fileWriter,
				dec.comment is null ? vd.comment : dec.comment,
				prevComments);
			memberStack[$ - 2].variables ~= Item(link, dec.name.text, summary, formatNode(vd.type));
		}
		if (vd.comment !is null && vd.autoDeclaration !is null) foreach (ident; vd.autoDeclaration.identifiers)
		{
			auto fileWithLink = pushSymbol(ident.text, first);
			File f = fileWithLink[0];
			string link = fileWithLink[1];

			scope(exit) popSymbol(f);

			auto fileWriter = f.lockingTextWriter;
			writeBreadcrumbs(fileWriter);

			string summary = writer.readAndWriteComment(fileWriter, vd.comment, prevComments);
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

		auto fileWriter = f.lockingTextWriter();
		if (first)
		{
			writeBreadcrumbs(fileWriter);
		}
		else
			f.writeln("<hr/>");
		{
			fileWriter.put(`<pre><code>`);
			auto formatter = new HarboredFormatter!(File.LockingTextWriter)(fileWriter);
			scope(exit) formatter.sink = File.LockingTextWriter.init;
			writeAttributes(formatter, fileWriter, attributes[$ - 1]);
			mixin(formattingCode);
			fileWriter.put("\n</code></pre>");
		}
		string summary = writer.readAndWriteComment(fileWriter, ad.comment, prevComments,
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
		auto fileWriter = f.lockingTextWriter();
		// Stuff above the function doc
		if (first)
		{
			writeBreadcrumbs(fileWriter);
		}
		else
			fileWriter.put("<hr/>");

		auto formatter = new HarboredFormatter!(File.LockingTextWriter)(fileWriter);
		scope(exit) formatter.sink = File.LockingTextWriter.init;

		// Function signature start //
		fileWriter.put(`<pre><code>`);
		// Attributes like public, etc.
		writeAttributes(formatter, fileWriter, attrs);
		// Return type and function name, with special case fo constructor
		static if (__traits(hasMember, typeof(fn), "returnType"))
		{
			if (fn.returnType)
			{
				formatter.format(fn.returnType);
				fileWriter.put(" ");
			}
			formatter.format(fn.name);
		}
		else
			fileWriter.put("this");
		// Template params
		if (fn.templateParameters !is null)
			formatter.format(fn.templateParameters);
		// Function params
		if (fn.parameters !is null)
			formatter.format(fn.parameters);
		// Attributes like const, nothrow, etc.
		foreach (a; fn.memberFunctionAttributes)
		{
			fileWriter.put(" ");
			formatter.format(a);
		}
		// Template constraint
		if (fn.constraint)
		{
			fileWriter.put(" ");
			formatter.format(fn.constraint);
		}
		fileWriter.put("\n</code></pre>");
		// Function signature end//

		string summary = writer.readAndWriteComment(fileWriter, fn.comment,
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
	 * Writes navigation breadcrumbs in HTML format to the given range.
	 */
	void writeBreadcrumbs(R)(ref R dst)
	{
		import std.array : join;
		import std.conv : to;
		import std.range : chain, only;
		import std.string: format;
		
		string heading;
		scope(exit) 
		{
			writer.writeBreadcrumbs(dst, heading);
		}

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
				heading ~= `<a href=%s>%s</a>.`.format(link(), stack[i]);
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
			heading  ~= `<a href=%s>%s</a>.`.format(link(), stack[i]);
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

			auto fileWriter = f.lockingTextWriter;
			writer.writeHeader(fileWriter, name, baseLength);
			writer.writeTOC(fileWriter, moduleName);
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
	/** Namespace stack of the current symbol,
	 *
	 * E.g. ["package", "subpackage", "module", "Class", "member"]
	 */
	string[] stack;
	/** Every item of this stack corresponds to a parent module/class/etc of the
	 * current symbol, but not package.
	 *
	 * Each Members struct is used to accumulate all members of that module/class/etc
	 * so the list of all members can be generated.
	 */
	Members[] memberStack;
	File searchIndex;
	TestRange[][size_t] unitTestMapping;
	const(ubyte[]) fileBytes;
	const(Config)* config;
	Writer writer;
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
