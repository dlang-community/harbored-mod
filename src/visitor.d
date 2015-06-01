/**
 * D Documentation Generator
 * Copyright: © 2014 Economic Modeling Specialists, Intl., © 2015 Ferdinand Majerech
 * Authors: Brian Schott, Ferdinand Majerech
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt Boost License 1.0)
 */
module visitor;

import std.algorithm;
import std.array: appender, empty, array, popBack, back, popFront, front;
import std.d.ast;
import std.d.lexer;
import std.file;
import std.path;
import std.stdio;
import std.string: format;
import std.typecons;

import config;
import ddoc.comments;
import item;
import symboldatabase;
import unittest_preprocessor;
import writer;

/**
 * Generates documentation for a (single) module.
 */
class DocVisitor(Writer) : ASTVisitor
{
	/**
	 * Params:
	 *
	 * config          = Configuration data, including macros and the output directory.
	 * database        = Stores information about modules and symbols for e.g. cross-referencing.
	 * unitTestMapping = The mapping of declaration addresses to their documentation unittests
	 * fileBytes       = The source code of the module as a byte array.
	 * writer          = Handles writing into generated files.
	 */
	this(ref const Config config, SymbolDatabase database,
	     TestRange[][size_t] unitTestMapping, const(ubyte[]) fileBytes, Writer writer)
	{
		this.config          = &config;
		this.database        = database;
		this.unitTestMapping = unitTestMapping;
		this.fileBytes       = fileBytes;
		this.writer          = writer;

		this.writer.processCode = &crossReference;
	}

	override void visit(const Module mod)
	{
		import std.conv : to;
		assert(mod.moduleDeclaration !is null, "DataGatherVisitor should have caught this");
		pushAttributes();
		stack = cast(string[]) mod.moduleDeclaration.moduleName.identifiers.map!(a => a.text).array;
		writer.prepareModule(stack);

		moduleName = stack.join(".").to!string;

		scope(exit) { writer.finishModule(); }

		// The module is the first and only top-level "symbol".
		bool dummyFirst;
		string link;
		auto fileWriter = writer.pushSymbol(stack, database, dummyFirst, link);
		scope(exit) { writer.popSymbol(); }

		writer.writeHeader(fileWriter, moduleName, stack.length - 1);
		writer.writeBreadcrumbs(fileWriter, stack, database);
		writer.writeTOC(fileWriter, moduleName);
		writer.writeSymbolStart(fileWriter, link);

		prevComments.length = 1;

		const comment = mod.moduleDeclaration.comment;
		memberStack.length = 1;

		mod.accept(this);

		writer.writeSymbolDescription(fileWriter,
		{
			memberStack.back.writeImports(fileWriter, writer);

			if (comment !is null)
			{
				writer.readAndWriteComment(fileWriter, comment, prevComments,
					null, getUnittestDocTuple(mod.moduleDeclaration));
			}
		});

		memberStack.back.write(fileWriter, writer);
		writer.writeSymbolEnd(fileWriter);
	}

	override void visit(const EnumDeclaration ed)
	{
		enum formattingCode = q{
		fileWriter.put("enum " ~ ad.name.text);
		if (ad.type !is null)
		{
			fileWriter.put(" : ");
			formatter.format(ad.type);
		}
		};
		visitAggregateDeclaration!(formattingCode, "enums")(ed);
	}

	override void visit(const EnumMember member)
	{
		// Document all enum members even if they have no doc comments.
		if (member.comment is null)
		{
			memberStack.back.values ~= Item("#", member.name.text, "");
			return;
		}
		auto dummy = appender!string();
		// No interest in detailed docs for an enum member.
		string summary = writer.readAndWriteComment(dummy, member.comment,
			prevComments, null, getUnittestDocTuple(member));
		memberStack.back.values ~= Item("#", member.name.text, summary);
	}

	override void visit(const ClassDeclaration cd)
	{
		enum formattingCode = q{
		fileWriter.put("class " ~ ad.name.text);
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
		fileWriter.put("template " ~ ad.name.text);
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
		fileWriter.put("struct " ~ ad.name.text);
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
		fileWriter.put("interface " ~ ad.name.text);
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
		if (ad.comment is null)
			return;
		bool first;
		if (ad.identifierList !is null) foreach (name; ad.identifierList.identifiers)
		{
			string itemURL;
			auto fileWriter = pushSymbol(name.text, first, itemURL);
			scope(exit) popSymbol(fileWriter);

			string type, summary;
			writer.writeSymbolDescription(fileWriter,
			{
				type = writeAliasType(fileWriter, name.text, ad.type);
				summary = writer.readAndWriteComment(fileWriter, ad.comment, prevComments);
			});

			memberStack[$ - 2].aliases ~= Item(itemURL, name.text, summary, type);
		}
		else foreach (initializer; ad.initializers)
		{
			string itemURL;
			auto fileWriter = pushSymbol(initializer.name.text, first, itemURL);
			scope(exit) popSymbol(fileWriter);

			string type, summary;
			writer.writeSymbolDescription(fileWriter,
			{
				type = writeAliasType(fileWriter, initializer.name.text, initializer.type);
				summary = writer.readAndWriteComment(fileWriter, ad.comment, prevComments);
			});

			memberStack[$ - 2].aliases ~= Item(itemURL, initializer.name.text, summary, type);
		}
	}

	override void visit(const VariableDeclaration vd)
	{
		// Write the variable attributes, type, name.
		void writeVariableHeader(R)(ref R dst, string typeStr, string nameStr)
		{
			writer.writeCodeBlock(dst,
			{
				assert(attributeStack.length > 0,
				    "Attributes stack must not be empty when writing variable attributes");
				auto formatter = writer.newFormatter(dst);
				scope(exit) { destroy(formatter.sink); }
				// Attributes like public, etc.
				writeAttributes(dst, formatter, attributeStack.back);
				dst.put(typeStr);
				dst.put(` `);
				dst.put(nameStr);
				// TODO also default value
			});
		}
		bool first;
		foreach (const Declarator dec; vd.declarators)
		{
			if (vd.comment is null && dec.comment is null)
				continue;
			string itemURL;
			auto fileWriter = pushSymbol(dec.name.text, first, itemURL);
			scope(exit) popSymbol(fileWriter);

			string typeStr = writer.formatNode(vd.type);
			string summary;
			writer.writeSymbolDescription(fileWriter,
			{
				writeVariableHeader(fileWriter, typeStr, dec.name.text);
				summary = writer.readAndWriteComment(fileWriter,
					dec.comment is null ? vd.comment : dec.comment,
					prevComments);
			});

			memberStack[$ - 2].variables ~= Item(itemURL, dec.name.text, summary, typeStr);
		}
		if (vd.comment !is null && vd.autoDeclaration !is null) foreach (ident; vd.autoDeclaration.identifiers)
		{
			string itemURL;
			auto fileWriter = pushSymbol(ident.text, first, itemURL);
			scope(exit) popSymbol(fileWriter);

			// TODO this was hastily updated to get harbored-mod to compile
			// after a libdparse update. Revisit and validate/fix any errors.
			string[] storageClasses;
			foreach(stor; vd.storageClasses)
			{
				storageClasses ~= str(stor.token.type);
			}

			string typeStr = storageClasses.canFind("enum") ? null : "auto";
			string summary;
			writer.writeSymbolDescription(fileWriter,
			{
				writeVariableHeader(fileWriter, typeStr, ident.text);
				summary = writer.readAndWriteComment(fileWriter, vd.comment, prevComments);
			});
			auto i = Item(itemURL, ident.text, summary, typeStr);
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
		attributeStack.back ~= dec.attributes;
		dec.accept(this);
		if (dec.attributeDeclaration is null)
			attributeStack.back = attributeStack.back[0 .. $ - dec.attributes.length];
	}

	override void visit(const AttributeDeclaration dec)
	{
		attributeStack.back ~= dec.attribute;
	}

	override void visit(const Constructor cons)
	{
		if (cons.comment is null)
			return;
		writeFnDocumentation("this", cons, attributeStack.back);
	}

	override void visit(const FunctionDeclaration fd)
	{
		if (fd.comment is null)
			return;
		writeFnDocumentation(fd.name.text, fd, attributeStack.back);
	}

	override void visit(const ImportDeclaration imp)
	{
		// public attribute must be specified explicitly for public imports.
		foreach(attr; attributeStack.back) if(attr.attribute.type == tok!"public")
		{
			foreach(i; imp.singleImports)
			{
				import std.conv;
				// Using 'dup' here because of std.algorithm's apparent
				// inability to work with const arrays. Probably not an
				// issue (imports are not hugely common), but keep the
				// possible GC overhead in mind.
				auto nameParts = i.identifierChain.identifiers
				                 .dup.map!(t => t.text).array;
				const name = nameParts.joiner(".").to!string;

				const knownModule = database.moduleNames.canFind(name);
				const link = knownModule ? writer.moduleLink(nameParts)
				                         : null;
				memberStack.back.publicImports ~=
					Item(link, name, null, null, imp);
			}
			return;
		}
		//TODO handle imp.importBindings as well? Need to figure out how it works.
	}

	// Optimization: don't allow visit() for these AST nodes to result in visit()
	// calls for their subnodes. This avoids most of the dynamic cast overhead.
	override void visit(const AssignExpression assignExpression) {}
	override void visit(const CmpExpression cmpExpression) {}
	override void visit(const TernaryExpression ternaryExpression) {}
	override void visit(const IdentityExpression identityExpression) {}
	override void visit(const InExpression inExpression) {}

	alias visit = ASTVisitor.visit;

private:
	/// Get the current protection attribute.
	IdType currentProtection()
	out(result)
	{
		assert([tok!"private", tok!"package", tok!"protected", tok!"public"].canFind(result),
		       "Unknown protection attribute");
	}
	body
	{
		foreach(a; attributeStack.back.filter!(a => a.attribute.type.isProtection))
		{
			return a.attribute.type;
		}
		return tok!"public";
	}

	/** Writes attributes to the range dst using formatter to format code.
	 *
	 * Params:
	 *
	 * dst       = Range to write to.
	 * formatter = Formatter to format the attributes with.
	 * attrs     = Attributes to write.
	 */
	final void writeAttributes(R, F)(ref R dst, F formatter, const(Attribute)[] attrs)
	{
		import std.d.lexer: IdType, isProtection, tok;
		IdType protection = currentProtection();
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


	void visitAggregateDeclaration(string formattingCode, string name, A)(const A ad)
	{
		bool first;
		if (ad.comment is null)
			return;

		string itemURL;
		auto fileWriter = pushSymbol(ad.name.text, first, itemURL);
		scope(exit) popSymbol(fileWriter);

		string summary;
		writer.writeSymbolDescription(fileWriter,
		{
			writer.writeCodeBlock(fileWriter,
			{
				auto formatter = writer.newFormatter(fileWriter);
				scope(exit) destroy(formatter.sink);
				assert(attributeStack.length > 0,
					"Attributes stack must not be empty when writing aggregate attributes");
				writeAttributes(fileWriter, formatter, attributeStack.back);
				mixin(formattingCode);
			});

			summary = writer.readAndWriteComment(fileWriter, ad.comment, prevComments,
				null, getUnittestDocTuple(ad));
		});

		mixin(`memberStack[$ - 2].` ~ name ~ ` ~= Item(itemURL, ad.name.text, summary);`);

		prevComments.length = prevComments.length + 1;
		ad.accept(this);
		prevComments.popBack();

		memberStack.back.write(fileWriter, writer);
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
	void writeFnDocumentation(Fn)(string name, Fn fn, const(Attribute)[] attrs)
	{
		bool first;
		string itemURL;
		auto fileWriter = pushSymbol(name, first, itemURL);
		scope(exit) popSymbol(fileWriter);

		string summary;
		writer.writeSymbolDescription(fileWriter,
		{
			auto formatter = writer.newFormatter(fileWriter);
			scope(exit) destroy(formatter.sink);

			// Write the function signature.
			writer.writeCodeBlock(fileWriter,
			{
				assert(attributeStack.length > 0,
				       "Attributes stack must not be empty when writing "
				       "function attributes");
				// Attributes like public, etc.
				writeAttributes(fileWriter, formatter, attrs);
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
				{
					fileWriter.put("this");
				}
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
			});

			summary = writer.readAndWriteComment(fileWriter, fn.comment,
				prevComments, fn.functionBody, getUnittestDocTuple(fn));
		});
		string fdName;
		static if (__traits(hasMember, typeof(fn), "name"))
			fdName = fn.name.text;
		else
			fdName = "this";
		auto fnItem = Item(itemURL, fdName, summary, null, fn);
		memberStack[$ - 2].functions ~= fnItem;
		prevComments.length = prevComments.length + 1;
		fn.accept(this);

		// The function may have nested functions/classes/etc, so at the very
		// least we need to close their files, and once public/private works even
		// document them.
		memberStack.back.write(fileWriter, writer);
		prevComments.popBack();
	}

	/**
	 * Writes an alias' type to the given range and returns it.
	 * Params:
	 *     dst  = The range to write to
	 *     name = the name of the alias
	 *     t    = the aliased type
	 * Returns: A string reperesentation of the given type.
	 */
	string writeAliasType(R)(ref R dst, string name, const Type t)
	{
		if (t is null)
			return null;
		string formatted = writer.formatNode(t);
		writer.writeCodeBlock(dst,
		{
			dst.put("alias %s = ".format(name));
			dst.put(formatted);
		});
		return formatted;
	}


	/** Generate links from symbols in input to files documenting those symbols.
	 *
	 * Note: The current implementation is far from perfect. It doesn't try to parse
	 * input; it just searches for alphanumeric words and patterns like
	 * "alnumword.otheralnumword" and asks SymbolDatabase to find a reference to them.
	 *
	 * TODO: Improve this by trying to parse input as D code first, only falling back
	 * to current implementation if the parsing fails. Parsing would only be used to
	 * correctly detect names, but must not reformat any code from input.
	 *
	 * Params:
	 *
	 * input = String to find symbols in.
	 *
	 * Returns:
	 *
	 * string with symbols replaced by links (links' format depends on Writer).
	 */
	string crossReference(string input) @trusted nothrow
	{
		import std.ascii;
		bool isNameCharacter(dchar c)
		{
			char c8 = cast(char)c;
			return c8 == c && (c8.isAlphaNum || "_.".canFind(c8));
		}

		auto app = appender!string();
		dchar prevC = '\0';
		dchar c;

		// Scan a symbol name. When done, both c and input.front will be set to
		// the first character after the name.
		string scanName()
		{
			auto scanApp = appender!string();
			while(!input.empty)
			{
				c = input.front;
				if(!isNameCharacter(c) && isNameCharacter(prevC)) { break; }

				scanApp.put(c);
				prevC = c;
				input.popFront();
			}
			return scanApp.data;
		}

		// There should be no UTF decoding errors as we validate text when loading
		// with std.file.readText().
		try while(!input.empty)
		{
			c = input.front;
			if(isNameCharacter(c) && !isNameCharacter(prevC))
			{
				string name = scanName();

				auto link = database.crossReference(writer, stack, name);
				size_t partIdx = 0;

				if(link !is null) writer.writeLink(app, link, { app.put(name); });
				// Attempt to cross-reference individual parts of the name
				// (e.g. "variable.method" will not match anything if
				// "variable" is a local variable "method" by itself may
				// still match something)
				else foreach(part; name.splitter("."))
				{
					if(partIdx++ > 0) { app.put("."); }

					link = database.crossReference(writer, stack, part);
					if(link !is null) writer.writeLink(app, link, { app.put(part); });
					else { app.put(part); }
				}
			}

			if(input.empty) { break; }

			// Even if scanName was called above, c is the first character
			// *after* scanName.
			app.put(c);
			prevC = c;
			// Must check again because scanName might have exhausted the input.
			input.popFront();
		}
		catch(Exception e)
		{
			import std.exception: assumeWontThrow;
			writeln("Unexpected exception when cross-referencing: ", e.msg)
				.assumeWontThrow;
		}

		return app.data;
	}

	/**
	 * Params:
	 *
	 * name    = The symbol's name
	 * first   = Set to true if this is the first time that pushSymbol has been
	 *           called for this name.
	 * itemURL = URL to use in the Item for this symbol will be written here.
	 *
	 * Returns: A range to write the symbol's documentation to.
	 */
	auto pushSymbol(string name, ref bool first, ref string itemURL)
	{
		import std.array : array, join;
		import std.string : format;
		stack ~= name;
		memberStack.length = memberStack.length + 1;

		// Sets first
		auto result = writer.pushSymbol(stack, database, first, itemURL);

		if(first)
		{
			writer.writeHeader(result, name, writer.moduleNameLength);
			writer.writeBreadcrumbs(result, stack, database);
			writer.writeTOC(result, moduleName);
		}
		else
		{
			writer.writeSeparator(result);
		}
		writer.writeSymbolStart(result, itemURL);
		return result;
	}

	void popSymbol(R)(ref R dst)
	{
		writer.writeSymbolEnd(dst);
		stack.popBack();
		memberStack.popBack();
		writer.popSymbol();
	}

	void pushAttributes() { attributeStack.length = attributeStack.length + 1; }

	void popAttributes() { attributeStack.popBack(); }


	/// The module name in "package.package.module" format.
	string moduleName;

	const(Attribute)[][] attributeStack;
	Comment[] prevComments;
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
	TestRange[][size_t] unitTestMapping;
	const(ubyte[]) fileBytes;
	const(Config)* config;
	/// Information about modules and symbols for e.g. cross-referencing.
	SymbolDatabase database;
	Writer writer;
}
