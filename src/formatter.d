/**
 * D Documentation Generator
 * Copyright: © 2014 Economic Modeling Specialists, Intl., © 2014 Ferdinand Majerech
 * Authors: Brian Schott, Ferdinand Majerech
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt Boost License 1.0)
 */
module formatter;

import std.d.ast;
import std.d.lexer;
import std.d.formatter;
import std.stdio;


/** Modified D formatter for Harbored.
 *
 * Currently the only modification is that multi-parameter parameter lists are split into
 * multiple lines.
 */
class HarboredFormatter(Sink) : Formatter!Sink
{
    /// Nesting level for nested parameter lists (see format(const Parameters)).
    private uint level;

    /// Function to process types with for cross-referencing.
    private string delegate(string) @safe nothrow crossReference;

    /**
     * Params:
     *
     * sink        = the output range that the formatted source code is placed in
     * processCode = Function to process types with for cross-referencing.
     * useTabs     = if true, tabs are used for indent levels instead of spaces
     * style       = the brace style
     * indentWidth = the number of spaces used for indentation if useTabs is false
     */
    this(Sink sink, string delegate(string) @safe nothrow crossReference,
         bool useTabs = false, IndentStyle style = IndentStyle.allman, uint indentWidth = 4)
    {
        this.crossReference = crossReference;
        super(sink, useTabs, style, indentWidth);
    }

    alias format = Formatter!Sink.format;

    /** A modified version of (libdparse) std.d.formatter.Formatter.format(const Parameters)
    * to format each parameter on a separate line.
    */
    override void format(const Parameters parameters)
    {
        debug(verbose) writeln("Parameters (HarboredFormatter)");

        // No need to break the list into multiple lines for a single argument
        // TODO ability to set this in "doxyfile"
        const maxParametersForSingleLineParameterList = 1;
        if(parameters.parameters.length <= maxParametersForSingleLineParameterList)
        {
            super.format(parameters);
            return;
        }
        level++;
        scope(exit) level--;
        put("(");
        foreach (count, param; parameters.parameters)
        {
            if (count) put(", ");
            put("\n");
            foreach(i; 0..level)
                put("    ");
            format(param);
        }
        if (parameters.hasVarargs)
        {
            if (parameters.parameters.length)
                put(", ");
            put("\n");
            foreach(i; 0..level)
                put("    ");
            put("...");
        }
        if(level > 1)
        {
            put("\n");
            foreach(i; 0..level)
                put("    ");
        }
        put(")");
    }

    // Overridden for builtin type referencing.
    override void format(const Type2 type2)
    {
        debug(verbose) writeln("Type2 (HarboredFormatter)");

        /**
        IdType builtinType;
        Symbol symbol;
        TypeofExpression typeofExpression;
        IdentifierOrTemplateChain identifierOrTemplateChain;
        IdType typeConstructor;
        Type type;
        **/

        if (type2.symbol !is null)
        {
            format(type2.symbol);
        }
        else if (type2.typeofExpression !is null)
        {
            format(type2.typeofExpression);
            if (type2.identifierOrTemplateChain)
            {
                put(".");
                format(type2.identifierOrTemplateChain);
            }
            return;
        }
        else if (type2.typeConstructor != tok!"")
        {
            put(tokenRep(type2.typeConstructor));
            put("(");
            format(type2.type);
            put(")");
        }
        else
        {
            // Link to language reference for builtin types.
            put(`<a href="http://dlang.org/type.html#basic-data-types">`);
            put(tokenRep(type2.builtinType));
            put("</a>");
        }
    }

    // Overridden for cross-referencing.
    override void format(const Token token)
    {
        debug(verbose) writeln("Token (HarboredFormatter) ", tokenRep(token));
        put(crossReference(tokenRep(token)));
    }

}

