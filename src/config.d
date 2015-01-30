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
	string[] tocAdditionalFileNames = [];
	string[] tocAdditionalStrings = [];
	string cssFileName = null;
	string outputDirectory = "./doc";
	string format = "html-aggregated";
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
			       std.getopt.config.passThrough, "F|config", &configFile);
			if(configFile !is null)
			{
			    loadConfigFile(configFile, true);
			}

			getopt(cliArgs, std.getopt.config.caseSensitive,
			       "m|macros", &newMacroFiles, "o|output-directory", &outputDirectory,
			       "h|help", &doHelp, "i|index", &indexFileName, 
			       "t|toc-additional", &tocAdditionalFileNames, 
			       "T|toc-additional-direct", &tocAdditionalStrings,
			       "e|exclude", &newExcludes,
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
				writefln("Config file '%s' not found", fileName);
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
			case "toc-additional":   tocAdditionalFileNames ~= value;           break;
			case "css":              cssFileName = value;                       break;
			case "output-directory": outputDirectory = value;                   break;
			case "exclude":          add(excludes, value);                      break;
			case "config":           if(value) { loadConfigFile(value, true); } break;
			case "source":           add(sourcePaths, value);                   break;
			default:                 writefln("Unknown key in config file: '%s'", key);
		}
	}
}

immutable string helpString = import("help");
immutable string defaultConfigString = import("hmod.cfg");
