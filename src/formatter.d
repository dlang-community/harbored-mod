/**
 * D Documentation Generator
 * Copyright: © 2014 Economic Modeling Specialists, Intl., © 2014 Ferdinand Majerech
 * Authors: Brian Schott, Ferdinand Majerech
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt Boost License 1.0)
 */
module formatter;

import std.d.ast;
import std.d.formatter;
import std.stdio;


/** Modified D formatter for Harbored.
 *
 * Currently the only modification is that multi-parameter parameter lists are split into
 * multiple lines.
 */
class HarboredFormatter(Sink) : Formatter!Sink
{
    /**
     * Params:
     *     sink = the output range that the formatted source code is placed in
     *     useTabs = if true, tabs are used for indent levels instead of spaces
     *     style = the brace style
     *     indenteWidth = the number of spaces used for indentation if useTabs is false
     */
    this(Sink sink, bool useTabs = false, IndentStyle style = IndentStyle.allman, uint indentWidth = 4)
    {
        super(sink, useTabs, style, indentWidth);
    }

    alias format = Formatter!Sink.format;

    /** A modified version of (libdparse) std.d.formatter.Formatter.format(const Parameters)
    * to format each parameter on a separate line.
    *
    * May be modified further, e.g. to allow cross-referencing.
    */
    override void format(const Parameters parameters)
    {
        debug(verbose) writeln("Parameters (HarboredFormatter)");

        /**
        Parameter[] parameters;
        bool hasVarargs;
        **/
        // No need to break the list into multiple lines for a single argument
        // TODO ability to set this in "doxyfile"
        const maxParametersForSingleLineParameterList = 1;
        if(parameters.parameters.length <= maxParametersForSingleLineParameterList)
        {
            super.format(parameters);
            return;
        }

        put("(");
        foreach (count, param; parameters.parameters)
        {
            if (count) put(", ");
            put("\n    ");
            format(param);
        }
        if (parameters.hasVarargs)
        {
            if (parameters.parameters.length)
                put(", ");
            put("\n    ");
            put("...");
        }
        put(")");
    }
}

