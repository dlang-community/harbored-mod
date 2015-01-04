/**
 * D Documentation Generator
 * Copyright: © 2014 Economic Modeling Specialists, Intl.
 * Authors: Brian Schott
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt Boost License 1.0)
 */
module main;

import std.algorithm;
import std.array;
import std.conv;
import std.d.ast;
import std.d.lexer;
import std.d.parser;
import std.file;
import std.getopt;
import std.path;
import std.stdio;

import config;
import macros;
import tocbuilder;
import unittest_preprocessor;
import visitor;


int main(string[] args)
{
	Config config;
	enum defaultConfigPath = "hmod.cfg";
	config.loadConfigFile(defaultConfigPath);
	config.loadCLI(args);
	
	if (config.doHelp)
	{
		writeln(helpString);
		return 0;
	}

	// Used to write default CSS/config with overwrite checking
	int writeProtected(string path, string content, string type)
	{
		if(path.exists)
		{
			writefln("'%s' exists. Overwrite? (y/N)", path);
			import std.ascii: toLower;
			char overwrite;
			readf("%s", &overwrite);
			if(overwrite.toLower != 'y')
			{
				writefln("Exited without overwriting '%s'", path);
				return 1;
			}
			writefln("Overwriting '%s'", path);
		}
		try
		{
		    std.file.write(path, content);
		}
		catch(Exception e)
		{
			writefln("Failed to write default %s to file `%s` : %s",
				type, path, e.msg);
			return 1;
		}
		return 0;
	}

	if (config.doGenerateCSSPath !is null)
	{
		return writeProtected(config.doGenerateCSSPath, stylecss, "CSS");
	}
	if(config.doGenerateConfig)
	{
		return writeProtected(defaultConfigPath, defaultConfigString, "config");
	}


	string[string] macros;
	try
		macros = readMacros(config.macroFileNames);
	catch (Exception e)
	{
		stderr.writeln(e.msg);
		return 1;
	}

	generateDocumentation(config, macros);

	return 0;
}

string[string] readMacros(const string[] macroFiles)
{
	string[string] rVal;
	foreach (k, v; ddoc.macros.DEFAULT_MACROS)
		rVal[k] = v;
	foreach (mf; macroFiles)
		readMacroFile(mf, rVal);
	return rVal;
}

void generateDocumentation(ref const(Config) config, string[string] macros)
{
	string[] files = getFilesToProcess(config.sourcePaths.dup);
	import std.stdio;
	stderr.writeln("Writing documentation to ", config.outputDirectory);

	mkdirRecurse(config.outputDirectory);

	File search = File(buildPath(config.outputDirectory, "search.js"), "w");
	search.writeln(`"use strict";`);
	search.writeln(`var items = [`);

	string[] moduleNames;
	string[string] moduleNameToDocPath;

	writeln("Collecting data for table of contents");
	foreach(modulePath; files)
	{
		string moduleName;
		string link;

		try
		{
			getDocumentationLink(config, modulePath, moduleName, link);
		}
		catch(Exception e)
		{
			stderr.writeln("Could not build a TOC entry for ", modulePath, ": ", e.msg);
			continue;
		}

		if (moduleName != "")
		{
			moduleNames ~= moduleName;
			moduleNameToDocPath[moduleName] = link;
		}
	}

	TocItem[] tocItems = buildTree(moduleNames, moduleNameToDocPath);

	string tocAdditional = config.tocAdditionalFileName is null 
	                     ? null : readText(config.tocAdditionalFileName);
	if (config.tocAdditionalFileName !is null)
	{
		// Hack so we don't have to pass all readAndWriteComments params to
		// writeTOC. TODO rewrite readAndWriteComments and other writing
		// functions so they generate strings and refactor them.
		const tempName = ".hmod-additional-toc-temp";
		auto temp = File(tempName, "w");
		readAndWriteComment(temp, tocAdditional, &config, macros);
		temp.close();
		tocAdditional = readText(tempName);
		std.file.remove(temp.name);
	}

	// Write index.html and style.css
	{
		File css = File(buildPath(config.outputDirectory, "style.css"), "w");
		css.write(getCSS(config.cssFileName));
		File js = File(buildPath(config.outputDirectory, "highlight.pack.js"), "w");
		js.write(hljs);
		File showHideJs = File(buildPath(config.outputDirectory, "show_hide.js"), "w");
		showHideJs.write(showhidejs);
		File index = File(buildPath(config.outputDirectory, "index.html"), "w");
		index.writeHeader("Index", 0);
		index.writeTOC(tocItems, tocAdditional);
		index.writeBreadcrumbs("Main Page");

		if (config.indexFileName !is null)
		{
			File indexFile = File(config.indexFileName);
			ubyte[] indexBytes = new ubyte[cast(uint) indexFile.size];
			indexFile.rawRead(indexBytes);
			readAndWriteComment(index, cast(string)indexBytes, &config, macros);
		}
		index.writeln(`
</div>
</div>
</body>
</html>`);
	}


	foreach (f; files)
	{
		writeln("Generating documentation for ", f);
		try
		{
			writeDocumentation(config, f, search, tocItems, macros, tocAdditional);
		}
		catch (Exception e)
		{
			stderr.writeln("Could not generate documentation for ", f, ": ", e.msg);
		}
	}
	search.writeln(`];`);
	search.writeln(searchjs);
}

/** Get the CSS content to write into style.css.
 *
 * If customCSS is not null, try to load from that file.
 */
string getCSS(string customCSS)
{
	if(customCSS is null) { return stylecss; }
	try
	{
		return readText(customCSS);
	}
	catch(Exception e)
	{
		stderr.writefln("Failed to load custom CSS `%s`: %s", customCSS, e.msg);
		return stylecss;
	}
}

/// Creates documentation for the module at the given path
void writeDocumentation(ref const Config config, string path, File search, TocItem[] tocItems,
	string[string] macros, string tocAdditional)
{
	LexerConfig lexConfig;
	lexConfig.fileName = path;
	lexConfig.stringBehavior = StringBehavior.source;

	File f = File(path);
	ubyte[] fileBytes = uninitializedArray!(ubyte[])(to!size_t(f.size));
	f.rawRead(fileBytes);
	StringCache cache = StringCache(1024 * 4);
	auto tokens = getTokensForParser(fileBytes, lexConfig, &cache).array;
	Module m = parseModule(tokens, path, null, &doNothing);
	TestRange[][size_t] unitTestMapping = getUnittestMap(m);
	auto visitor = new DocVisitor(config, macros, search,
		unitTestMapping, fileBytes, tocItems, tocAdditional);
	visitor.visit(m);
}

/// Gets link (in output directory) and module name for documentation of specified module.
void getDocumentationLink(ref const Config config, string modulePath,
	ref string moduleName, ref string link)
{
	LexerConfig lexConfig;
	lexConfig.fileName = modulePath;
	lexConfig.stringBehavior = StringBehavior.source;

	File f = File(modulePath);
	ubyte[] fileBytes = uninitializedArray!(ubyte[])(to!size_t(f.size));
	f.rawRead(fileBytes);
	StringCache cache = StringCache(1024 * 4);
	auto tokens = getTokensForParser(fileBytes, lexConfig, &cache).array;
	Module m = parseModule(tokens, modulePath, null, &doNothing);
	auto visitor = new DocVisitor(config, null, File.init, null,
		fileBytes, null, null);
	visitor.moduleInitLocation(m);
	moduleName = visitor.moduleName;
	link = visitor.link;
}

string[] getFilesToProcess(string[] paths)
{
	auto files = appender!(string[])();
	foreach (arg; paths)
	{
		if (isDir(arg)) foreach (string fileName; dirEntries(arg, "*.{d,di}", SpanMode.depth))
			files.put(expandTilde(fileName));
		else if (isFile(arg))
			files.put(expandTilde(arg));
		else
			stderr.writeln("Could not open `", arg, "`");
	}
	return files.data;
}


void doNothing(string, size_t, size_t, string, bool) {}

immutable string hljs = import("highlight.pack.js");
immutable string stylecss = import("style.css");
immutable string searchjs = import("search.js");
immutable string showhidejs = import("show_hide.js");
