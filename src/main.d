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

import allocator;
import config;
import macros;
import symboldatabase;
import tocbuilder;
import unittest_preprocessor;
import visitor;
import writer;


int main(string[] args)
{
	import std.datetime;
	const startTime = Clock.currStdTime;
	scope(exit) 
	{
		writefln("Time spent: %.3fs", (Clock.currStdTime - startTime) / 10_000_000.0); 
		// DO NOT CHANGE. hmod-dub reads this.
		writefln("Peak memory usage (kiB): %s", peakMemoryUsageK()); 
	}

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
		writefln("Generating CSS file '%s'", config.doGenerateCSSPath);
		return writeProtected(config.doGenerateCSSPath, stylecss, "CSS");
	}
	if(config.doGenerateConfig)
	{
		writefln("Generating config file '%s'", defaultConfigPath);
		return writeProtected(defaultConfigPath, defaultConfigString, "config");
	}


	try
	{
		config.macros = readMacros(config.macroFileNames);
	}
	catch (Exception e)
	{
		stderr.writeln(e.msg);
		return 1;
	}

	switch(config.format)
	{
		case "html-simple": generateDocumentation!HTMLWriterSimple(config); break;
		case "html-aggregated": generateDocumentation!HTMLWriterAggregated(config); break;
		default: writeln("Unknown format: ", config.format);
	}

	return 0;
}

string[string] readMacros(const string[] macroFiles)
{
	string[string] rVal;
	foreach (k, v; ddoc.macros.DEFAULT_MACROS)
		rVal[k] = v;
	rVal["D"]    = `<code class="d_inlinecode">$0</code>`;
	// These seem to be defined in Phobos, and apparently work in D code
	// using some of its modules? Either way, needed for compatibility.
	rVal["HTTP"] = "<a href=\"http://$1\">$+</a>";
	rVal["WEB"]  = "$(HTTP $1,$2)";
	foreach (mf; macroFiles)
		readMacroFile(mf, rVal);
	return rVal;
}

void generateDocumentation(Writer)(ref Config config)
{
	string[] files = getFilesToProcess(config);
	import std.stdio;
	stderr.writeln("Writing documentation to ", config.outputDirectory);

	mkdirRecurse(config.outputDirectory);

	File search = File(buildPath(config.outputDirectory, "search.js"), "w");
	search.writeln(`"use strict";`);
	search.writeln(`var items = [`);

	auto database =
		gatherData(config, new Writer(config, search, null, null), files);

	TocItem[] tocItems = buildTree(database.moduleNames, database.moduleNameToLink);

	enum noFile = "missing file";
	string[] tocAdditionals =
		config.tocAdditionalFileNames.map!(path => path.exists ? readText(path) : noFile)
		                             .array ~
		config.tocAdditionalStrings;
	if(!tocAdditionals.empty) foreach(ref text; tocAdditionals)
	{
		auto html = new Writer(config, search, null, null);
		auto writer = appender!string();
		html.readAndWriteComment(writer, text);
		text = writer.data;
	}

	foreach (f; database.moduleFiles)
	{
		writeln("Generating documentation for ", f);
		try
		{
			writeDocumentation!Writer(config, database, f, search, tocItems,
			                          tocAdditionals);
		}
		catch (Exception e)
		{
			stderr.writeln("Could not generate documentation for ", f, ": ", e.msg);
		}
	}
	search.writeln(`];`);
	search.writeln(searchjs);

	// Write index.html and style.css
	{
		writeln("Generating main page");
		File css = File(buildPath(config.outputDirectory, "style.css"), "w");
		css.write(getCSS(config.cssFileName));
		File js = File(buildPath(config.outputDirectory, "highlight.pack.js"), "w");
		js.write(hljs);
		File showHideJs = File(buildPath(config.outputDirectory, "show_hide.js"), "w");
		showHideJs.write(showhidejs);
		File index = File(buildPath(config.outputDirectory, "index.html"), "w");

		auto fileWriter = index.lockingTextWriter;
		auto html = new Writer(config, search, tocItems, tocAdditionals);
		html.writeHeader(fileWriter, "Index", 0);
		const projectStr = config.projectName ~ " " ~ config.projectVersion;
		const heading = projectStr == " " ? "Main Page" : (projectStr ~ ": Main Page");
		html.writeBreadcrumbs(fileWriter, heading);
		html.writeTOC(fileWriter);

		// Index content added by the user.
		if (config.indexFileName !is null)
		{
			File indexFile = File(config.indexFileName);
			ubyte[] indexBytes = new ubyte[cast(uint) indexFile.size];
			indexFile.rawRead(indexBytes);
			html.readAndWriteComment(fileWriter, cast(string)indexBytes);
		}

		// A full list of all modules.
		if(database.moduleNames.length <= config.maxModuleListLength)
		{
			html.writeModuleList(fileWriter, database);
		}

		index.writeln(HTML_END);
	}


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
void writeDocumentation(Writer)(ref Config config, SymbolDatabase database, 
	string path, File search, TocItem[] tocItems, string[] tocAdditionals)
{
	LexerConfig lexConfig;
	lexConfig.fileName = path;
	lexConfig.stringBehavior = StringBehavior.source;

	File f = File(path);
	ubyte[] fileBytes = uninitializedArray!(ubyte[])(to!size_t(f.size));
	import core.memory;
	scope(exit) { GC.free(fileBytes.ptr); }
	f.rawRead(fileBytes);
	StringCache cache = StringCache(1024 * 4);
	auto tokens = getTokensForParser(fileBytes, lexConfig, &cache).array;
	import std.typecons: scoped;
	auto allocator = scoped!(CAllocatorImpl!(Allocator));

	Module m = parseModule(tokens, path, allocator, &doNothing);

	TestRange[][size_t] unitTestMapping = getUnittestMap(m);
	
	auto htmlWriter  = new Writer(config, search, tocItems, tocAdditionals);
	auto visitor = new DocVisitor!Writer(config, database, unitTestMapping, 
	                                     fileBytes, htmlWriter);
	visitor.visit(m);

	if(allocator.impl.primary.bytesHighTide > 16 * 1024 * 1024)
	{
		writeln("More than 16MiB allocated by parser. Stats:");
		allocator.impl.primary.writeStats();
	}
}

/** Get .d/.di files to process.
 *
 * Files that don't exist, are bigger than config.maxFileSizeK or could not be
 * opened will be ignored.
 *
 * Params:
 *
 * config = Access to config to get source file and directory paths get max file size.
 * 
 * Returns: Paths of files to process.
 */
string[] getFilesToProcess(ref const Config config)
{
	auto paths = config.sourcePaths.dup;
	auto files = appender!(string[])();
	void addFile(string path)
	{
		const size = path.getSize();
		if(size > config.maxFileSizeK * 1024)
		{
			writefln("WARNING: '%s' (%skiB) bigger than max file size (%skiB), "
			         "ignoring", path, size / 1024, config.maxFileSizeK);
			return;
		}
		files.put(path);
	}

	foreach (arg; paths)
	{
		if(!arg.exists)
			stderr.writefln("WARNING: '%s' does not exist, ignoring", arg);
		else if (arg.isDir) foreach (string fileName; arg.dirEntries("*.{d,di}", SpanMode.depth))
			addFile(fileName.expandTilde);
		else if (arg.isFile)
			addFile(arg.expandTilde);
		else
			stderr.writefln("WARNING: Could not open '%s', ignoring", arg);
	}
	return files.data;
}


void doNothing(string, size_t, size_t, string, bool) {}

immutable string hljs = import("highlight.pack.js");
immutable string stylecss = import("style.css");
immutable string searchjs = import("search.js");
immutable string showhidejs = import("show_hide.js");
ulong peakMemoryUsageK()
{
    version(linux)
    {
        try
        {
            import std.exception;
            auto line = File("/proc/self/status").byLine().filter!(l => l.startsWith("VmHWM"));
            enforce(!line.empty, new Exception("No VmHWM in /proc/self/status"));
            return line.front.split()[1].to!ulong;
        }
        catch(Exception e)
        {
            writeln("Failed to get peak memory usage: ", e);
            return 0;
        }
    }
    else 
    {
        writeln("peakMemoryUsageK not implemented on non-Linux platforms");
        return 0;
    }
}
