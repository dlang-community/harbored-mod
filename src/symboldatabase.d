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

	/** Get a link to documentation of symbol specified by word (if word is a symbol).
	 *
	 * Searching for a symbol matching to word is done in 3 stages:
	 * 1. Assume word starts by a module name (with or without parent packages of the
	 *    module), look for matching modules, and if any, try to find the symbol there.
	 * 2. If 1. didn't find anything, assume word refers to a local symbol (parent
	 *    scope - siblings of the symbol being documented or current scope - children
	 *    of that symbol).
	 * 3. If 2. didn't find anything, assume word refers to a symbol in any module;
	 *    search for a symbol with identical full name (but without the module part)
	 *    in all modules.
	 *
	 * Params:
	 *
	 * writer     = Writer used to determine links.
	 * scopeStack = Scope of the symbol the documentation of which contains word.
	 * word       = Word to cross-reference.
	 *
	 * Returns: link if a matching symbol was found, null otherwise.
	 */
	string crossReference(Writer)(Writer writer, string[] scopeStack, string word)
	{
		string result;
		// Don't cross-reference nonsense
		if(word.splitter(".").empty || word.endsWith(".")) { return null; }

		// Search for a nested child with specified name stack in a members tree.
		// If found, return true and rewrite the members tree pointer. The
		// optional deleg argument can be used to execute code in each iteration.
		//
		// (e.g. for "File.writeln" nameStack would be ["File", "writeln"] and 
		// this would look for members.children["File"].children["writeln"])
		bool findNested(Parts)(ref MembersTree* m, Parts nameStack,
		                       void delegate(size_t partIdx, MembersTree* members) deleg = null)
		{
			auto members = m;
			size_t partIdx;
			foreach(part; nameStack)
			{
				if(!(part in members.children)) { return false; }
				members = part in members.children; 
				if(deleg) { deleg(partIdx++, members); }
			}
			m = members;
			return true;
		}

		// If module name is "tharsis.util.traits", this first checks if
		// word starts with("tharsis.util.traits"), then "util.traits" and
		// then "traits".
		bool startsWithPartOf(Splitter)(Splitter wParts, Splitter mParts)
		{
			while(!mParts.empty)
			{
				if(wParts.startsWith(mParts)) { return true; }
				mParts.popFront;
			}

			return false;
		}

		// Search for the symbol in specified module, return true if found.
		bool searchInModule(string modName)
		{
			// Parts of the symbol name within the module.
			string wordLocal = word;
			// Remove the part of module name the word starts with.
			wordLocal.skipOver(".");
			foreach(part; modName.splitter(".")) if(wordLocal.startsWith(part))
			{
				wordLocal.skipOver(part);
				wordLocal.skipOver(".");
			}

			MembersTree* members = modName in modules;
			assert(members !is null, "Can't search in a nonexistent module");

			auto parts = wordLocal.split(".");
			if(!findNested(members, parts)) { return false; }
			result = writer.symbolLink(modName.split("."), parts);
			return true;
		}

		// Search for a matching symbol assuming word starts by (part of) the name
		// of the module containing the symbol.
		bool searchAssumingExplicitModule(ref string result)
		{
			auto parts = word.splitter(".");
			// Avoid e.g. "typecons" automatically referencing to std.typecons;
			// at least 2 parts must be specified (e.g. "std.typecons" or
			// "typecons.Tuple" but not just "typecons" or "Tuple" ("Tuple"
			// would still be found by searchInModulesTopLevel))
			if(parts.walkLength <= 1) { return false; }

			// Start by assuming fully qualified name.
			// If word is fully prefixed by modName, it almost certainly refers
			// to that module (unless there is a module the name of which
			// *ends* with same string in another package and the word refers
			// to a symbol in *that* module. To handle that very unlikely case,
			// we don't return false if we fail to find the symbol in the module)
			foreach(modName; modules.byKey) if(parts.startsWith(modName.splitter(".")))
			{
				if(searchInModule(modName)) { return true; }
			}
			// If not fully qualified name, assume the name is prefixed at
			// least by a part of a module name. If it is, look in that module.
			foreach(modName; modules.byKey) if(startsWithPartOf(parts, modName.splitter(".")))
			{
				if(searchInModule(modName)) { return true; }
			}

			return false;
		}

		// Search for a matching symbol in the local scope (scopeStack) - children
		// of documented symbol and its parent scope - siblings of the symbol.
		bool searchLocal(ref string result)
		{
			MembersTree* membersScope;
			MembersTree* membersParent;
			string thisModule;

			// For a fully qualified name, we need module name (thisModule),
			// scope containing the symbol (scopeLocal for current scope,
			// scopeLocal[0 .. $ - 1] for parent scope) *and* symbol name in
			// the scope.
			string[] scopeLocal;

			// Find the module with the local scope.
			foreach(modName; modules.byKey) if(scopeStack.startsWith(modName.splitter(".")))
			{
				thisModule = modName;

				scopeLocal = scopeStack;
				scopeLocal.skipOver(modName.splitter("."));

				MembersTree* members = &modules[modName];
				void saveScopes(size_t depth, MembersTree* members)
				{
					const maxDepth = scopeLocal.length;
					if(depth == maxDepth - 1)      { membersScope = members; }
					else if(depth == maxDepth - 2) { membersParent = members; }
				}
				if(findNested(members, scopeLocal, &saveScopes))
				{
					break;
				}
			}

			// Search for the symbol specified by word in a members tree.
			// This assumes word directly names a member of the tree.
			bool searchMembers(string[] scope_, MembersTree* members)
			{
				auto parts = word.split(".");
				if(!findNested(members, parts)) { return false; }
				result = writer.symbolLink(thisModule.split("."), scope_ ~ parts);
				return true;
			}


			if(membersScope && searchMembers(scopeLocal, membersScope))
			{
				return true;
			}
			if(membersParent && searchMembers(scopeLocal[0 .. $ - 1], membersParent))
			{
				return true;
			}

			return false;
		}

		// Search for a matching symbol in top-level scopes of all modules. For a
		// non-top-level sumbol to match, it must be prefixed by a top-level symbol,
		// e.g. "Array.clear" instead of just "clear"
		bool searchInModulesTopLevel(ref string result)
		{
			auto parts = word.splitter(".");
			// Search in top-level scopes of each module.
			foreach(moduleName, ref MembersTree membersRef; modules)
			{
				MembersTree* members = &membersRef;
				if(!findNested(members, parts)) { continue; }

				result = writer.symbolLink(moduleName.split("."), parts.array);
				return true;
			}
			return false;
		}

		if(searchAssumingExplicitModule(result)) { return result; }
		if(searchLocal(result))                  { return result; }
		if(searchInModulesTopLevel(result))      { return result; }
		return null;
	}

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
		}
		else foreach (initializer; ad.initializers)
		{
			string itemLink;
			MembersTree* members = pushSymbol(initializer.name.text, itemLink);
			scope(exit) popSymbol();
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

	// Optimization: don't allow visit() for these AST nodes to result in visit()
	// calls for their subnodes. This avoids most of the dynamic cast overhead.
	override void visit(const AssignExpression assignExpression) {}
	override void visit(const CmpExpression cmpExpression) {}
	override void visit(const TernaryExpression ternaryExpression) {}
	override void visit(const IdentityExpression identityExpression) {}
	override void visit(const InExpression inExpression) {}

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
		if(!(name in members.children)) 
		{
			members.children[name] = MembersTree.init;
		}
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
