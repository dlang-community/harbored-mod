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
import std.exception: enforce;
import std.range;
import std.stdio;
import std.string: join, split;

import allocator;
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
	database.preCache();

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

	/// Get module data for specified module.
	SymbolDataModule moduleData(string moduleName)
	{
		auto mod = moduleName in modules;
		enforce(mod !is null,
		        new Exception("No such module: " ~ moduleName));
		assert(mod.type == SymbolType.Module,
		       "A non-module MembersTree in SymbolDatabase.modules");
		return mod.dataModule;
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

		string symbolLink(S1, S2)(S1 modStack, S2 symStack)
		{
			return writer.symbolLink(symbolStack(modStack, symStack));
		}

		/// Does a module with specified name exists?
		bool moduleExists(string moduleName)
		{
			MembersTree* node = &modulesTree;
			foreach(part; moduleName.splitter("."))
			{
				// can happen if moduleName looks e.g. like "a..b"
				if(part == "") { return false; }
				node = part in node.children;
				if(node is null) { return false; }
			}
			return node.type == SymbolType.Module;
		}

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
				members = part in members.children;
				if(!members) { return false; }
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
			// '.' prefix means module scope - which is what we're
			// handling here, but need to remove the '.' so we don't
			// try to look for symbol "".
			while(wordLocal.startsWith(".")) { wordLocal.popFront(); }
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
			result = symbolLink(modName.split("."), parts);
			return true;
		}

		// Search for a matching symbol assuming word starts by (part of) the name
		// of the module containing the symbol.
		bool searchAssumingExplicitModule(ref string result)
		{
			// No module name starts by "." - if we use "." we
			// usually mean a global symbol.
			if(word.startsWith(".")) { return false; }
			
			auto parts = word.splitter(".");
			// Avoid e.g. "typecons" automatically referencing to std.typecons;
			// at least 2 parts must be specified (e.g. "std.typecons" or
			// "typecons.Tuple" but not just "typecons" or "Tuple" ("Tuple"
			// would still be found by searchInModulesTopLevel))
			if(parts.walkLength <= 1) { return false; }

			// Start by assuming fully qualified name.
			// If word is fully prefixed by a module name, it almost certainly
			// refers to that module (unless there is a module the name of which
			// *ends* with same string in another package and the word refers
			// to a symbol in *that* module. To handle that very unlikely case,
			// we don't return false if we fail to find the symbol in the module)
			string prefix;
			foreach(part; parts)
			{
				prefix ~= part;
				// Use searchInModule for speed.
				if(moduleExists(prefix) && searchInModule(prefix))
				{
					return true;
				}
				prefix ~= ".";
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
			// a '.' prefix means we're *not* looking in the local scope.
			if(word.startsWith(".")) { return false; }
			MembersTree* membersScope;
			MembersTree* membersParent;
			string thisModule;

			// For a fully qualified name, we need module name (thisModule),
			// scope containing the symbol (scopeLocal for current scope,
			// scopeLocal[0 .. $ - 1] for parent scope) *and* symbol name in
			// the scope.
			string[] scopeLocal;

			string prefix;
			foreach(part; scopeStack)
			{
				prefix ~= part;
				scope(exit) { prefix ~= "."; }
				if(!moduleExists(prefix)) { continue; }
				thisModule = prefix;

				scopeLocal = scopeStack;
				scopeLocal.skipOver(thisModule.splitter("."));

				MembersTree* members = &modules[thisModule];
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
				result = symbolLink(thisModule.split("."), scope_ ~ parts);
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
			string wordLocal = word;
			// '.' prefix means module scope - which is what we're
			// handling here, but need to remove the '.' so we don't
			// try to look for symbol "".
			while(wordLocal.startsWith(".")) { wordLocal.popFront(); }
			auto parts = wordLocal.split(".");

			// Search in top-level scopes of each module.
			foreach(moduleName, ref MembersTree membersRef; modules)
			{
				MembersTree* members = &membersRef;
				if(!findNested(members, parts)) { continue; }

				result = symbolLink(moduleName.split("."), parts);
				return true;
			}
			return false;
		}

		if(searchAssumingExplicitModule(result)) { return result; }
		if(searchLocal(result))                  { return result; }
		if(searchInModulesTopLevel(result))      { return result; }
		return null;
	}

	/** Get a range describing a symbol with specified name.
	 *
	 * Params:
	 *
	 * moduleStack = Module name stack (module name split by ".").
	 * symbolStack = Symbol name stack (symbol name in the module split by ".").
	 *
	 * Returns: An InputRange describing the fully qualified symbol name.
	 *          Every item of the range will be a struct describing a part of the
	 *          name, with `string name` and `SymbolType type` members.
	 *          E.g. for `"std.stdio.File"` the range items would be 
	 *          `{name: "std", type: Package}, {name: "stdio", type: Module},
	 *          {name: "File", type: Class}`.
	 * 
	 * Note: If the symbol does not exist, the returned range will only contain 
	 *       items for parent symbols that do exist (e.g. if moduleStack is
	 *       ["std", "stdio"], symbolStack is ["noSuchThing"]), the symbolStack
	 *       will describe the "std" package and "stdio" module, but will contain
	 *       no entry for "noSuchThing".
	 * 
	 */
	auto symbolStack(S1, S2)(S1 moduleStack, S2 symbolStack)
	{
		assert(!moduleStack.empty,
		       "Can't get a symbol stack with no module stack");
		
		struct SymbolStack 
		{
		private:
			SymbolDatabase database;
			S1 moduleStack;
			S2 symbolStack;

			MembersTree* currentSymbol;
			string moduleName;

			this(SymbolDatabase db, S1 modStack, S2 symStack)
			{
				database    = db;
				moduleStack = modStack;
				symbolStack = symStack;
				delve(false);
			}
		public:
			auto front()
			{
				assert(!empty, "Can't get front of an empty range");
				struct Result 
				{
					string name;
					SymbolType type;
				}
				return Result(moduleStack.empty ? symbolStack.front : moduleStack.front,
				              currentSymbol.type);
			}
			
			void popFront()
			{
				assert(!empty, "Can't pop front of an empty range");
				if(!moduleStack.empty) 
				{
					moduleStack.popFront(); 
					delve(moduleStack.empty);
				}
				else
				{
					symbolStack.popFront(); 
					delve(false);
				}
			}
			
			bool empty()
			{
				return currentSymbol is null;
			}

			void delve(bool justFinishedModule)
			{
				if(!moduleStack.empty) with(database)
				{
					if(!moduleName.empty) { moduleName ~= "."; }
					moduleName ~= moduleStack.front;
					currentSymbol = currentSymbol is null
					              ? (moduleStack.front in modulesTree.children)
					              : (moduleStack.front in currentSymbol.children);
					return;
				}
				if(!symbolStack.empty)
				{
					if(justFinishedModule) with(database)
					{
						currentSymbol = moduleName in modules;
						assert(currentSymbol !is null,
						       "A module that's in moduleTree "
						       "must be in modules too");
					}
					currentSymbol = symbolStack.front in currentSymbol.children;
					return;
				}
				currentSymbol = null;
			}
		}

		return SymbolStack(this, moduleStack, symbolStack);
	}

private:
	/** Pre-compute any data structures needed for fast cross-referencing.
	 *
	 * Currently used for modulesTree, which allows quick decisions on whether a
	 * module exists.
	 */
	void preCache()
	{
		foreach(name; modules.byKey)
		{
			auto parts = name.splitter(".");
			MembersTree* node = &modulesTree;
			foreach(part; parts)
			{
				node.type = SymbolType.Package;
				MembersTree* child = part in node.children;
				if(child is null) 
				{
					node.children[part] = MembersTree.init;
					child = part in node.children;
				}
				node = child;
			}
			// The leaf nodes of the module tree are packages.
			node.type = SymbolType.Module;
		}
	}

	/// Member trees of all modules, indexed by full module names.
	MembersTree[string] modules;

	/// Allows to quickly determine whether a module exists. Built by preCache.
	MembersTree modulesTree;

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


/// Enumberates types of symbols in the symbol database.
enum SymbolType: ubyte
{
	/// A package with no module file (package.d would be considered a module).
	Package,
	/// A module.
	Module,
	/// An alias.
	Alias,
	/// An enum.
	Enum,
	/// A class.
	Class,
	/// A struct.
	Struct,
	/// An interface.
	Interface,
	/// A function (including e.g. constructors).
	Function,
	/// A template (not a template function/template class/etc).
	Template,
	/// Only used for enum members at the moment.
	Value,
	/// A variable member.
	Variable
}

/// Data we keep track of for a module.
struct SymbolDataModule 
{
	/// Summary comment of the module, *not* processes by Markdown.
	string summary;
}

private:

// Reusing Members here is a very quick hack, and we may need something better than a
// tree of AA's if generating docs for big projects is too slow.
/// Recursive tree of all members of a symbol.
struct MembersTree
{
	/// Members of children of this tree node.
	MembersTree[string] children;

	/// Type of this symbol.
	SymbolType type;

	union 
	{
		/// Data specific for a module symbol.
		SymbolDataModule dataModule;
		//TODO data for any other symbol types. In a union to save space.
	}
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
	import core.memory;
	scope(exit) { GC.free(fileBytes.ptr); }

	// Parse the module.
	LexerConfig lexConfig;
	lexConfig.fileName = modulePath;
	lexConfig.stringBehavior = StringBehavior.source;
	auto tokens = getTokensForParser(fileBytes, lexConfig, &database.cache).array;
	import main: doNothing;

	import std.typecons;
	auto allocator = scoped!(CAllocatorImpl!Allocator);
	
	Module m = parseModule(tokens, modulePath, allocator, &doNothing);
	if(allocator.impl.primary.bytesHighTide > 16 * 1024 * 1024)
	{
		writeln("More than 16MiB allocated by parser. Stats:");
		allocator.impl.primary.writeStats();
	}


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

		database.modules[moduleName].type = SymbolType.Module;
		database.modules[moduleName].dataModule.summary = 
			commentSummary(mod.moduleDeclaration.comment);

		mod.accept(this);
	}

	/// Gather data about various members ///

	override void visit(const EnumDeclaration ed)
	{
		visitAggregateDeclaration!(SymbolType.Enum)(ed);
	}

	// Document all enum members even if they have no doc comments.
	override void visit(const EnumMember member)
	{
		// Link to the enum owning the member (enum members themselves have no
		// files/detailed explanations).
		MembersTree* members = pushSymbol(member.name.text, SymbolType.Value);
		scope(exit) popSymbol();
	}

	override void visit(const ClassDeclaration cd)
	{
		visitAggregateDeclaration!(SymbolType.Class)(cd);
	}

	override void visit(const TemplateDeclaration td)
	{
		visitAggregateDeclaration!(SymbolType.Template)(td);
	}

	override void visit(const StructDeclaration sd)
	{
		visitAggregateDeclaration!(SymbolType.Struct)(sd);
	}

	override void visit(const InterfaceDeclaration id)
	{
		visitAggregateDeclaration!(SymbolType.Interface)(id);
	}

	override void visit(const AliasDeclaration ad)
	{
		if (ad.comment is null)
			return;

		if (ad.identifierList !is null) foreach (name; ad.identifierList.identifiers)
		{
			MembersTree* members = pushSymbol(name.text, SymbolType.Alias);
			scope(exit) popSymbol();
		}
		else foreach (initializer; ad.initializers)
		{
			MembersTree* members = pushSymbol(initializer.name.text, SymbolType.Alias);
			scope(exit) popSymbol();
		}
	}

	override void visit(const VariableDeclaration vd)
	{
		foreach (const Declarator dec; vd.declarators)
		{
			if (vd.comment is null && dec.comment is null)
				continue;
			MembersTree* members = pushSymbol(dec.name.text, SymbolType.Variable);
			scope(exit) popSymbol();
		}
		if (vd.comment !is null && vd.autoDeclaration !is null) foreach (ident; vd.autoDeclaration.identifiers)
		{
			MembersTree* members = pushSymbol(ident.text, SymbolType.Variable);
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
	/** If the comment starts with a summary, return it, otherwise return null.
	 *
	 * Note: as libdparse does not seem to recognize summaries correctly (?),
	 * we simply assume the first section of the comment to be the summary.
	 */
	string commentSummary(string comment)
	{
		if(comment.empty) 
		{
			return null; 
		}

		import core.exception: RangeError;
		try
		{
			import ddoc.comments;
			auto app = appender!string();
			comment.unDecorateComment(app);
			Comment c = parseComment(app.data, cast(string[string])config.macros);
			
			if (c.sections.length)
			{
				return c.sections[0].content;
			}
		}
		catch(RangeError e)
		{
			writeln("RangeError");
			// Writer.readAndWriteComment will catch this too and
			// write an error message. Not kosher to catch Errors
			// but unfortunately needed with libdparse ATM (2015).
			return null;
		}
		return null;
	}

	void visitAggregateDeclaration(SymbolType type, A)(const A ad)
	{
		if (ad.comment is null)
			return;

		// pushSymbol will push to stack, add tree entry and return MembersTree
		// containing that entry so we can also add the aggregate to the correct
		// Item array
		MembersTree* members = pushSymbol(ad.name.text, type);
		scope(exit) popSymbol();

		ad.accept(this);
	}

	void visitFunctionDeclaration(Fn)(string name, Fn fn)
	{
		MembersTree* members = pushSymbol(name, SymbolType.Function);
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
	 * name = The symbol's name
	 * type = Type of the symbol.
	 *
	 * Returns: Tree of the *parent* symbol of the pushed symbol.
	 */
	MembersTree* pushSymbol(string name, SymbolType type)
	{
		auto parentStack = symbolStack;
		symbolStack ~= name;

		MembersTree* members = database.getMembers(moduleName, parentStack);
		if(!(name in members.children)) 
		{
			members.children[name] = MembersTree.init;
			members.children[name].type = type;
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
