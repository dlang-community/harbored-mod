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
import visitor;
import unittest_preprocessor;
import macros;
import tocbuilder;

int main(string[] args)
{
	string[] macroFiles;
	string[] excludes;
	string outputDirectory;
	bool help;
	string indexContent;
	string customCSS;
	string generateCSSPath;

	getopt(args, std.getopt.config.caseSensitive,
		"m|macros", &macroFiles, "o|output-directory", &outputDirectory,
		"h|help", &help, "i|index", &indexContent, "e|exclude", &excludes,
		"c|css", &customCSS, "C|generate-css", &generateCSSPath);

	if (help)
	{
		writeln(helpString);
		return 0;
	}
	try if (generateCSSPath !is null)
	{
		std.file.write(generateCSSPath, stylecss);
		return 0;
	}
	catch(Exception e)
	{
		writefln("Failed to generate default CSS to file `%s` : %s", 
			generateCSSPath, e.msg);
		return 1;
	}

	string[string] macros;
	try
		macros = readMacros(macroFiles);
	catch (Exception e)
	{
		stderr.writeln(e.msg);
		return 1;
	}

	if (outputDirectory is null)
		outputDirectory = "./doc";

	generateDocumentation(outputDirectory, indexContent, customCSS, macros, args[1 .. $]);

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

void generateDocumentation(string outputDirectory, string indexContent,
	string customCSS, string[string] macros, string[] args)
{
	string[] files = getFilesToProcess(args);
	import std.stdio;
	stderr.writeln("Writing documentation to ", outputDirectory);

	mkdirRecurse(outputDirectory);

	File search = File(buildPath(outputDirectory, "search.js"), "w");
	search.writeln(`"use strict";`);
	search.writeln(`var items = [`);

	string[] moduleNames;
	string[string] moduleNameToDocPath;

	writeln("Collecting data for table of contents");
	foreach(modulePath; files)
	{
		string moduleName;
		string location;

		try
		{
			getDocumentationLocation(outputDirectory, modulePath, moduleName, location);
		}
		catch(Exception e)
		{
			stderr.writeln("Could not build a TOC entry for ", modulePath, ": ", e.msg);
			continue;
		}
		string path = (location.length > 2 && location[0 .. 2] == "./")
			? stripLeadingDirectory(location[2 .. $])
			: location;
		if (moduleName != "")
		{
			moduleNames ~= moduleName;
			moduleNameToDocPath[moduleName] = path;
		}
	}

	TocItem[] tocItems = buildTree(moduleNames, moduleNameToDocPath);

	// Write index.html and style.css
	{
		File css = File(buildPath(outputDirectory, "style.css"), "w");
		css.write(getCSS(customCSS));
		File js = File(buildPath(outputDirectory, "highlight.pack.js"), "w");
		js.write(hljs);
		File index = File(buildPath(outputDirectory, "index.html"), "w");
		index.writeHeader("Index", 0);
		index.writeTOC(tocItems);
		index.writeBreadcrumbs("Main Page");

		if (indexContent !is null)
		{
			File indexContentFile = File(indexContent);
			ubyte[] indexContentBytes = new ubyte[cast(uint) indexContentFile.size];
			indexContentFile.rawRead(indexContentBytes);
			readAndWriteComment(index, cast(string) indexContentBytes, macros);
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
			writeDocumentation(outputDirectory, f, macros, search, tocItems);
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
void writeDocumentation(string outputDirectory, string path,
	string[string] macros, File search, TocItem[] tocItems)
{
	LexerConfig config;
	config.fileName = path;
	config.stringBehavior = StringBehavior.source;

	File f = File(path);
	ubyte[] fileBytes = uninitializedArray!(ubyte[])(to!size_t(f.size));
	f.rawRead(fileBytes);
	StringCache cache = StringCache(1024 * 4);
	auto tokens = getTokensForParser(fileBytes, config, &cache).array;
	Module m = parseModule(tokens, path, null, &doNothing);
	TestRange[][size_t] unitTestMapping = getUnittestMap(m);
	DocVisitor visitor = new DocVisitor(outputDirectory, macros, search,
		unitTestMapping, fileBytes, tocItems);
	visitor.visit(m);
}

/// Gets location and module name for documentation of specified module.
void getDocumentationLocation(string outputDirectory, string modulePath,
	ref string moduleName, ref string location)
{
	LexerConfig config;
	config.fileName = modulePath;
	config.stringBehavior = StringBehavior.source;

	File f = File(modulePath);
	ubyte[] fileBytes = uninitializedArray!(ubyte[])(to!size_t(f.size));
	f.rawRead(fileBytes);
	StringCache cache = StringCache(1024 * 4);
	auto tokens = getTokensForParser(fileBytes, config, &cache).array;
	Module m = parseModule(tokens, modulePath, null, &doNothing);
	DocVisitor visitor = new DocVisitor(outputDirectory, null, File.init, null,
		fileBytes, null);
	visitor.moduleInitLocation(m);
	moduleName = visitor.moduleName;
	location = visitor.location;
}

string[] getFilesToProcess(string[] args)
{
	auto files = appender!(string[])();
	foreach (arg; args)
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

enum helpString = `
Generates documentation for D source code.

Usage:
    doctool [Options] file.d
    doctool [Options] directory1/ directory2/ ...

Options:
    --macros | -m MACRO_FILE
        Specifies a macro definition file

    --output-directory | -o DIR
        Writes the generated documentation to the given directory. If this
        option is not specified, documentation will be written to a folder
        called "doc" in the current directory.

    --exclude | -e MODULE_NAME
        Exclude the given module or package from the generated documentation.
        By default no modules or packages will be excluded unless they do not
        contain a module declaration.

    --index | -i DDOC_FILE
        Use DDOC_FILE as the content of the index.html page. By default this
        page will be blank.

    --css | -c CSS_FILE
        Use CSS_FILE to style the documentation instead of using default CSS.

    --generate-css | -C CSS_OUT_FILE
        Generate default CSS file and write it to CSS_OUT_FILE. This file can
        be modified and then passed using the --css option.

    --help | -h
        Prints this message.
`;

void doNothing(string, size_t, size_t, string, bool) {}

immutable string hljs = import("highlight.pack.js");
immutable string stylecss = import("style.css");
immutable string searchjs = import("search.js");
