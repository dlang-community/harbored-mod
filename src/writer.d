/**
 * D Documentation Generator
 * Copyright: © 2014 Economic Modeling Specialists, Intl., Ferdinand Majerech
 * Authors: Brian Schott, Ferdinand Majerech
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt Boost License 1.0)
 */
module writer;


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

class HTMLWriter
{
	/** Construct a HTMLWriter.
	 *
	 * Params:
	 *
	 * config        = Configuration data, including macros and the output directory.
	 * searchIndex   = A file where the search information will be written
	 * tocItems      = Items of the table of contents to write into each documentation file.
	 * tocAdditional = Additional content for the table of contents sidebar.
	 */
	this(ref const Config config, string[string] macros, File searchIndex,
	     TocItem[] tocItems, string tocAdditional)
	{
		this.config = &config;
		this.macros = macros;
		this.searchIndex = searchIndex;
		this.tocItems = tocItems;
		this.tocAdditional = tocAdditional;
	}

private:
	const(Config)* config;
	string[string] macros;
	File searchIndex;
	TocItem[] tocItems;
	string tocAdditional;
}
