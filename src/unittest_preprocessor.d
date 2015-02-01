/**
 * D Documentation Generator
 * Copyright: © 2014 Economic Modeling Specialists, Intl.
 * Authors: Brian Schott
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt Boost License 1.0)
 */

module unittest_preprocessor;

import std.typecons;
import std.d.ast;
import std.d.lexer;

/**
 * $(UL $(LI First field: the byte index of the opening brace of the unittest)
 * $(LI Second field: the byte index of the closing brace of the unittest)
 * $(LI Third field: the comment attached to the unittest))
 */
alias TestRange = Tuple!(size_t, size_t, string);

/**
 * Params:
 *     m = the module
 * Returns: A mapping of declaration addresses to an array of documentation
 *     unittest blocks for that declaration
 */
TestRange[][size_t] getUnittestMap(const Module m)
{
	UnittestVisitor visitor = new UnittestVisitor;
	visitor.visit(m);
	return visitor.mapping;
}

private:

class UnittestVisitor : ASTVisitor
{
	alias visit = ASTVisitor.visit;

	override void visit(const ModuleDeclaration modDec)
	{
		setPrevNode(modDec);
	}

	override void visit(const Unittest uTest)
	{
		setUnittest(uTest);
	}

	override void visit(const FunctionDeclaration fd)
	{
		setPrevNode(fd);
	}

	override void visit(const TemplateDeclaration td)
	{
		setPrevNode(td);
		pushScope();
		td.accept(this);
		popScope();
	}

	mixin template VisitScope(T)
	{
		override void visit(const T s)
		{
			pushScope();
			s.accept(this);
			popScope();
		}
	}

	mixin VisitScope!Module;
	mixin VisitScope!BlockStatement;
	mixin VisitScope!StructBody;

	mixin template VisitAggregate(T)
	{
		override void visit(const T d)
		{
			setPrevNode(d);
			d.accept(this);
		}
	}

	mixin VisitAggregate!ClassDeclaration;
	mixin VisitAggregate!InterfaceDeclaration;
	mixin VisitAggregate!StructDeclaration;
	mixin VisitAggregate!UnionDeclaration;

	// Optimization: don't allow visit() for these AST nodes to result in visit()
	// calls for their subnodes. This avoids most of the dynamic cast overhead.
	override void visit(const AssignExpression assignExpression) {}
	override void visit(const CmpExpression cmpExpression) {}
	override void visit(const TernaryExpression ternaryExpression) {}
	override void visit(const IdentityExpression identityExpression) {}
	override void visit(const InExpression inExpression) {}

private:

	void setUnittest(const Unittest test)
	{
//		import std.stdio;
		if (test.comment is null)
			return;
		if (prevNodeStack.length == 0)
			return;
		if (prevNodeStack[$ - 1] == 0)
			return;
//		writeln("Mapping unittest at ", test.blockStatement.startLocation,
//			" to declaration at ", prevNodeStack[$ - 1]);
		mapping[prevNodeStack[$ - 1]] ~= TestRange(
			test.blockStatement.startLocation,
			test.blockStatement.endLocation,
			test.comment);
	}

	void pushScope()
	{
		prevNodeStack.length = prevNodeStack.length + 1;
		prevNodeStack[$ - 1] = 0;
	}

	void popScope()
	{
		prevNodeStack = prevNodeStack[0 .. $ - 1];
	}

	void setPrevNode(T)(const T node)
	{
		prevNodeStack[$ - 1] = cast(size_t) (cast(void*) node);
	}

	size_t[] prevNodeStack;
	TestRange[][size_t] mapping;
 }
