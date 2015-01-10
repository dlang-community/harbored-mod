/**
 * D Documentation Generator
 * Copyright: © 2014 Economic Modeling Specialists, Intl., © 2015 Ferdinand Majerech
 * Authors: Ferdinand Majerech
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt Boost License 1.0)
 */
module symboldatabase;

import std.algorithm;
import std.array: popBack, back, empty, popFront;
import std.d.ast;
import std.d.lexer;
import std.d.parser;
import std.range;
import std.stdio;
import std.string: join, split;

import config;
import item;


/** Gather data about modules to document into a SymbolDatabase and return the database.
 *
 * Params:
 *
 * config = harbored-mod configuration.
 * writer = Writer (e.g. HTMLWriter), used to determine links for symbols (as Writer
 *          decides where to put symbols).
 * files  = Filenames of all modules to document.
 *
 * Returns: SymbolDatabase with collected data.
 */
SymbolDatabase gatherData(Writer)(ref const(Config) config, Writer writer, string[] files)
{
	writeln("Collecting data about modules and symbols");
	auto database = new SymbolDatabase;

	foreach(modulePath; files)
	{
		gatherModuleData(config, database, writer, modulePath);
	}

	return database;
}
class SymbolDatabase
{
	/// Names of modules to document.
	string[] moduleNames;
	/// File paths of modules to document.
	string[] moduleFiles;

	/// `moduleNameToLink["pkg.module"]` gets link to module `pkg.module`
	string[string] moduleNameToLink;

	/// Cache storing strings used in AST nodes of the parsed modules.
	private StringCache cache;

	/// Construct a symbol database.
	this()
	{
		cache = StringCache(1024 * 4);
	}

	//TODO if all the AAs are too slow, try RedBlackTree before completely overhauling


private:
	/// Member trees of all modules, indexed by module names.
	MembersTree[string] modules;

	/// Get members of symbol with specified name stack in specified module.
	MembersTree* getMembers(string moduleName, string[] symbolStack)
	{
		MembersTree* members = &modules[moduleName];
		foreach(namePart; symbolStack)
		{
			members = &members.children[namePart];
		}
		return members;
	}
}

private:

// Reusing Members here is a very quick hack, and we may need something better than a
// tree of AA's if generating docs for big projects is too slow.
/// Recursive tree of all members of a symbol.
struct MembersTree
{
	/// Members of this tree node (e.g. module or class).
	Members members;
	alias members this;

	/// Members of children of this tree node.
	MembersTree[string] children;
}


/** Gather data about symbols in a module into a SymbolDatabase.
 *
 * Writes directly into the passed SymbolDatabase.
 *
 * Params:
 *
 * config     = harbored-mod configuration.
 * database   = SymbolDatabase to gather data into.
 * writer     = Writer (e.g. HTMLWriter), used to determine links for symbols (as Writer
 *              decides where to put symbols).
 * modulePath = Path of the module file.
 */
void gatherModuleData(Writer)
	(ref const(Config) config, SymbolDatabase database, Writer writer, string modulePath)
{
	// Load the module file.
	import std.file;
	ubyte[] fileBytes;
	try
	{
		fileBytes = cast(ubyte[])modulePath.readText!(char[]);
	}
	catch(Exception e)
	{
		writefln("Failed to load file %s: will be ignored", modulePath);
		return;
	}

	// Parse the module.
	LexerConfig lexConfig;
	lexConfig.fileName = modulePath;
	lexConfig.stringBehavior = StringBehavior.source;
	auto tokens = getTokensForParser(fileBytes, lexConfig, &database.cache).array;
	import main: doNothing;
	Module m = parseModule(tokens, modulePath, null, &doNothing);

	// Gather data.
	auto visitor = new DataGatherVisitor!Writer(config, database, writer, modulePath);
	visitor.visit(m);
}

/** Visits AST nodes to gather data about symbols in a module.
 */
class DataGatherVisitor(Writer) : ASTVisitor
{
	/** Construct a DataGatherVisitor.
	 * Params:
	 *
	 * config   = Configuration data, including macros and the output directory.
	 * database = Database to gather data into.
	 * writer   = Used to determine link strings.
	 * fileName = Module file name.
	 */
	this(ref const Config config, SymbolDatabase database, Writer writer, string fileName)
	{
		this.config   = &config;
		this.database = database;
		this.writer   = writer;
		this.fileName = fileName;
	}

	alias visit = ASTVisitor.visit;

	/// Determines module name and adds a MemberTree for it to the database.
	override void visit(const Module mod)
	{
		import std.range : chain, iota, join, only;
		import std.conv : to;

		if (mod.moduleDeclaration is null)
		{
			writefln("Ignoring file %s: no 'module' declaration", fileName);
			return;
		}
		auto stack = cast(string[])mod.moduleDeclaration.moduleName.identifiers.map!(a => a.text).array;

		foreach(exclude; config.excludes)
		{
			// If module name is pkg1.pkg2.mod, we first check
			// "pkg1", then "pkg1.pkg2", then "pkg1.pkg2.mod"
			// i.e. we only check for full package/module names.
			if(iota(stack.length + 1).map!(l => stack[0 .. l].join(".")).canFind(exclude))
			{
				writeln("Excluded module ", stack.join("."));
				return;
			}
		}

		moduleName = stack.join(".").to!string;
		database.moduleNames ~= moduleName;
		database.moduleFiles ~= fileName;
		database.moduleNameToLink[moduleName] = writer.moduleLink(stack);
		database.modules[moduleName] = MembersTree.init;

		mod.accept(this);
	}

	/// Gather data about various members ///

	override void visit(const EnumDeclaration ed)
	{
		visitAggregateDeclaration!"enums"(ed);
	}

	// Document all enum members even if they have no doc comments.
	override void visit(const EnumMember member)
	{
		// Link to the enum owning the member (enum members themselves have no
		// files/detailed explanations).
		const link = writer.symbolLink(moduleName.split("."), symbolStack);
		string dummyLink;
		MembersTree* members = pushSymbol(member.name.text, dummyLink);
		scope(exit) popSymbol();
		members.values ~= Item(link, member.name.text, null, null, member);
	}

	override void visit(const ClassDeclaration cd)
	{
		visitAggregateDeclaration!"classes"(cd);
	}

	override void visit(const TemplateDeclaration td)
	{
		visitAggregateDeclaration!"templates"(td);
	}

	override void visit(const StructDeclaration sd)
	{
		visitAggregateDeclaration!"structs"(sd);
	}

	override void visit(const InterfaceDeclaration id)
	{
		visitAggregateDeclaration!"interfaces"(id);
	}

	override void visit(const AliasDeclaration ad)
	{
		if (ad.comment is null)
			return;

		if (ad.identifierList !is null) foreach (name; ad.identifierList.identifiers)
		{
			string itemLink;
			MembersTree* members = pushSymbol(name.text, itemLink);
			scope(exit) popSymbol();

			members.aliases ~= Item(itemLink, name.text, null, null, ad);
		}
		else foreach (initializer; ad.initializers)
		{
			string itemLink;
			MembersTree* members = pushSymbol(initializer.name.text, itemLink);
			scope(exit) popSymbol();

			members.aliases ~= Item(itemLink, initializer.name.text, null, null, ad);
		}
	}

	override void visit(const VariableDeclaration vd)
	{
		foreach (const Declarator dec; vd.declarators)
		{
			if (vd.comment is null && dec.comment is null)
				continue;
			string itemLink;
			MembersTree* members = pushSymbol(dec.name.text, itemLink);
			scope(exit) popSymbol();

			members.variables ~= Item(itemLink, dec.name.text, null, null, dec);
		}
		if (vd.comment !is null && vd.autoDeclaration !is null) foreach (ident; vd.autoDeclaration.identifiers)
		{
			string itemLink;
			MembersTree* members = pushSymbol(ident.text, itemLink);
			scope(exit) popSymbol();

			string[] storageClasses;
			foreach(stor; vd.storageClasses)
			{
				storageClasses ~= str(stor.token.type);
			}
			auto i = Item(itemLink, ident.text, null, null);
			if (storageClasses.canFind("enum"))
				members.enums ~= i;
			else
				members.variables ~= i;
		}
	}

	override void visit(const Constructor cons)
	{
		if (cons.comment is null)
			return;
		visitFunctionDeclaration("this", cons);
	}

	override void visit(const FunctionDeclaration fd)
	{
		if (fd.comment is null)
			return;
		visitFunctionDeclaration(fd.name.text, fd);
	}


private:
	void visitAggregateDeclaration(string name, A)(const A ad)
	{
		if (ad.comment is null)
			return;

		string itemLink;
		// pushSymbol will push to stack, add tree entry and return MembersTree
		// containing that entry so we can also add the aggregate to the correct
		// Item array
		MembersTree* members = pushSymbol(ad.name.text, itemLink);
		scope(exit) popSymbol();

		mixin(`members.%s ~= Item(itemLink, ad.name.text, null, null, ad);`.format(name));

		ad.accept(this);
	}

	void visitFunctionDeclaration(Fn)(string name, Fn fn)
	{
		string itemLink;
		MembersTree* members = pushSymbol(name, itemLink);
		scope(exit) popSymbol();

		string fdName;
		static if (__traits(hasMember, typeof(fn), "name"))
			fdName = fn.name.text;
		else
			fdName = "this";
		auto fnItem = Item(itemLink, fdName, null, null, fn);
		members.functions ~= fnItem;
		fn.accept(this);
	}

	/** Push a symbol to the stack, moving into its scope.
	 *
	 * Params:
	 *
	 * name     = The symbol's name
	 * itemLink = URL to use in the Item for this symbol will be written here.
	 *
	 * Returns: Tree of the *parent* symbol of the pushed symbol.
	 */
	MembersTree* pushSymbol(string name, ref string itemLink)
	{
		auto parentStack = symbolStack;
		symbolStack ~= name;
		itemLink = writer.symbolLink(moduleName.split("."), symbolStack);

		MembersTree* members = database.getMembers(moduleName, parentStack);
		if(!(name in members.children)) { members.children[name] = MembersTree.init; }
		return members;
	}

	/// Leave scope of a symbol, moving back to its parent.
	void popSymbol()
	{
		symbolStack.popBack();
	}

	/// Harbored-mod configuration.
	const(Config)* config;
	/// Database we're gathering data into.
	SymbolDatabase database;
	/// Used to determine links to symbols.
	Writer writer;
	/// Filename of this module.
	string fileName;
	/// Name of this module in D code.
	string moduleName;
	/** Namespace stack of the current symbol, without the package/module name.
	 *
	 * E.g. ["Class", "member"]
	 */
	string[] symbolStack;
}
