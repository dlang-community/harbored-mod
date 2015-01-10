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
