/**
 * D Documentation Generator
 * Copyright: © 2014 Economic Modeling Specialists, Intl., Ferdinand Majerech
 * Authors: Ferdinand Majerech
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt Boost License 1.0)
 */


/// Config loading and writing.
module config;


import std.algorithm;
import std.array;
import std.stdio;
import std.string;



/** Stores configuration data loaded from command-line or config files.
 *
 * Note that multiple calls to loadCLI/loadConfigFile are supported; data loaded with
 * earlier calls is overwritten by later calls (e.g. command-line overriding config file),
 * except arrays like macroFileNames/excludes/sourcePaths: successive calls always add to
 * these arrays instead of overwriting them, so e.g. extra modules can be excluded with
 * command-line.
 */
struct Config
{
	bool doHelp = false;
	bool doGenerateConfig = false;
	string doGenerateCSSPath = null;
	string[] macroFileNames = [];
	string indexFileName = null;
	string tocAdditionalFileName = null;
	string cssFileName = null;
	string outputDirectory = "./doc";
	/// Names of packages and modules to exclude from generated documentation.
	string[] excludes = [];
	string[] sourcePaths = [];

	/** Load config options from CLI arguments.
	 *
	 * Params:
	 *
	 * cliArgs = Command-line args.
	 */
	void loadCLI(string[] cliArgs)
	{
		import std.getopt;

		// If the user requests a config file, we must look for that option first
		// and process it before other options so the config file doesn't override
		// CLI options (it would override them if loaded after processing the CLI
		// options).
		string configFile;
		string[] newMacroFiles;
		string[] newExcludes;
		try
		{
			getopt(cliArgs, std.getopt.config.caseSensitive,
			       std.getopt.config.passThrough, "f|config", &configFile);
			if(configFile !is null)
			{
			    loadConfigFile(configFile, true);
			}

			getopt(cliArgs, std.getopt.config.caseSensitive,
			       "m|macros", &newMacroFiles, "o|output-directory", &outputDirectory,
			       "h|help", &doHelp, "i|index", &indexFileName, 
			       "t|toc-additional", &tocAdditionalFileName, "e|exclude", &newExcludes,
			       "c|css", &cssFileName, "C|generate-css", &doGenerateCSSPath,
			       "g|generate-cfg", &doGenerateConfig);
		}
		catch(Exception e)
		{
			writeln("Failed to parse command-line arguments: ", e.msg);
			writeln("Maybe try 'hmod -h' for help information?");
			return;
		}

		macroFileNames  ~= newMacroFiles;
		excludes        ~= newExcludes;
		sourcePaths     ~= cliArgs[1 .. $];
	}

	/** Load specified config file and add loaded data to the configuration.
	 *
	 * Params:
	 *
	 * fileName        = Name of the config file.
	 * requestedByUser = If true, this is not the default config file and has been
	 *                   explicitly requested by the user, i.e. we have to inform the
	 *                   user if the file was not found.
	 *
	 */
	void loadConfigFile(string fileName, bool requestedByUser = false)
	{
		import std.conv: to;
		import std.file: exists, isFile;
		import std.typecons: tuple;

		if(!fileName.exists || !fileName.isFile)
		{
			if(requestedByUser)
			{
				writeln("Config file '%s' not found");
			}
			return;
		}

		writefln("Loading config file '%s'", fileName);
		try
		{
			auto keyValues = File(fileName)
			                 .byLine
			                 .map!(l => l.until!(c => ";#".canFind(c)))
			                 .map!array
			                 .map!strip
			                 .filter!(s => !s.empty && s.canFind("="))
			                 .map!(l => l.findSplit("="))
			                 .map!(p => tuple(p[0].strip.to!string, p[2].strip.to!string))
			                 .filter!(p => !p[0].empty);

			foreach(key, value; keyValues)
			{
				processConfigValue(key, value);
			}
		}
		catch(Exception e)
		{
			writefln("Failed to parse config file '%s': %s", fileName, e.msg);
		}
	}

private:
	void processConfigValue(string key, string value)
	{
		// ensures something like "macros = " won't add an empty string value
		void add(ref string[] array, string value)
		{
			if(!value.empty) { array ~= value; }
		}

		switch(key)
		{
			case "help":             doHelp = true;                             break;
			case "generate-cfg":     doGenerateConfig = true;                   break;
			case "generate-css":     doGenerateCSSPath = value;                 break;
			case "macros":           add(macroFileNames, value);                break;
			case "index":            indexFileName = value;                     break;
			case "toc-additional":   tocAdditionalFileName = value;             break;
			case "css":              cssFileName = value;                       break;
			case "output-directory": outputDirectory = value;                   break;
			case "exclude":          add(excludes, value);                      break;
			case "config":           if(value) { loadConfigFile(value, true); } break;
			case "source":           add(sourcePaths, value);                   break;
			default:                 writefln("Unknown key in config file: '%s'", key);
		}
	}
}


enum helpString = `
Generates documentation for D source code.

Usage:
    hmod [Options] file.d
    hmod [Options] directory1/ directory2/ ...

Examples:
    hmod source
        Write documentation for source code in directory 'source' to directory 'doc'.
        If file 'hmod.cfg' exists, load more configuration options from there.

    hmod source -o doc/api
        Write documentation for source code in directory 'source' to directory 'doc/api'.
        If file 'hmod.cfg' exists, load more configuration options from there.

    hmod -g
        Generate default configuration file as 'hmod.cfg'

    hmod -C style.css
        Generate default CSS style as 'style.css'

    hmod source -c style.css -e package1.module -e package2 -i index.ddoc
        Write documentation for source code in directory 'source' to directory 'doc',
        using CSS style 'style.css' and main page content from 'index.ddoc', but
        don't generate documentation for module 'package1.module' and package 'package2'.
        If file 'hmod.cfg' exists, load more configuration options from there.

Options:
    --help | -h
        Prints this message.

    --output-directory | -o DIR
        Writes the generated documentation to the given directory. If this
        option is not specified, documentation will be written to a folder
        called "doc" in the current directory.

    --exclude | -e MODULE_NAME
        Exclude given module or package from the generated documentation.
        By default no modules or packages will be excluded unless they do not
        contain a module declaration.

        Example: '-e tharsis.util -e tharsis.entity.componentbuffer'
        This will exclude package tharsis.util and module
        tharsis.entity.gamestate.

    --index | -i DDOC_MD_FILE
        Use DDOC_MD_FILE as the content of the index.html page. By default this
        page will be blank.

    --toc-additional | -t DDOC_MD_FILE
        Use DDOC_MD_FILE as additional content of the table of contents.

    --generate-cfg | -g
        Generate the default configuration file and write it into 'hmod.cfg'. This file
        can be used to store configuration options instead of passing them on
        command-line. By default, hmod loads configuration from this file if it exists.
        See also: --config

    --css | -c CSS_FILE
        Use CSS_FILE to style the documentation instead of using default CSS.
        See also: --generate-css

    --generate-css | -C CSS_OUT_FILE
        Generate default CSS file and write it to CSS_OUT_FILE. This file can
        be modified and then passed using the --css option.

    --config | -f CONFIG_FILE
        Load hmod configuration from specified file.
        By default, hmod loads configuration from './hmod.cfg',
        if such a file exists.

        Note that any configuration option specified in the config file is
        overridden if the same option is specified as a command-line
        argument.

    --macros | -m MACRO_FILE
        Specifies a DDoc macro definition file to use. Multiple macro files
        can be used by using this option more than once.
`;


string defaultConfigString = `
# This file contains configuration options for harbored-mod (hmod).
#
# By default, hmod loads configuration from file 'hmod.cfg' in the directory from where
# hmod is running, if such file exists. These configuration options can also be passed
# as command-line options for hmod, overriding contents of the config file, if any,
# with the exception of options that allow multiple values (such as 'exclude' or
# 'macros') where the values specified as command-line options are *added* to the values
# in config file.



# Source code files or directories to document. Specify more than once to document more
# files/directories, e.g:
#
#   source = ./source
#   source = ./thirdparty
#
# This will document both the source code in the ./source/ and ./thirdparty/ directories.
#
# For DUB (http://code.dlang.org) projects, './source' is usually a good setting here.
source = .


# Directory where the generated documentation will be written.
output-directory = ./doc


# Modules or packages to exclude from generated documentation. Specify more than once to
# exclude more modules/packages, e.g:
#
#   exclude = tharsis.util
#   exclude = tharsis.entity.gamestate
#
# This will exclude both the package (or module) tharsis.util and module (or package)
# tharsis.entity.gamestate .

exclude =


# DDoc+markdown source of the main page of your documentation. Currently the main page is
# blank by default; this can be used to fill it with something useful.

index =


# DDoc+markdown source of additional content to add to the table of contents sidebar.
# Useful e.g. to add links to tutorials.

toc-additional =


# CSS file to use for styling. Can be used to replace the default style.
# To create a new style, you can start by generating the default style file with
# 'hmod --generate-css CSS_OUT_FILE' (CSS_OUT_FILE is name the generated file will have)
# and then modifying the CSS to get the desired style.

css =


# File to load DDoc macros from. Can be used to override builtin macros or add new ones.
# Can be specified more than once to use multiple macro files, e.g.:
#
#   macros = macros.ddoc
#   macros = moremacros.ddoc


macros =

# Additional config file to load, if needed. Configuration options in specified file will
# override or add to any options specified before this line, and will be overridden by
# any options after this line. Think of it as including the config file in this file.

config =



#---------------------------------------------------------------------------
# Configuration options **only** useful for harbored-mod testing
#---------------------------------------------------------------------------
# Uncommenting these will result in printing help information; only useful for testing.
#
# # Print help message.
#
# help
#
#
# # Generate default CSS file and write it to specified file.
# generate-css = hmod-style.css
#
#
# # Generate default config file and write it to 'hmod.cfg'.
#
# generate-cfg
`;
