// Shared catalog of D snippets, used by tour and explorer examples
//
// Fields:
//   id = stable key
//   label = dropdown / demo-select text
//   panes = comma list of explorer panes to show: lex, parse, sema, ast, ir, iropt, asm, diag
//   height = iframe px in the tour
//   code = the D source

export const EXAMPLES = [
	{
		id: "tokenKinds",
		label: "Token kinds (lexer)",
		panes: "lex",
		height: 300,
		code: `extern(C++)
struct C
{
	int i = -1;
	long j = 2L;
}

pure nothrow @safe @nogc:

string getString()
{
	return "abc" ~ \`def\`c;
}
`,
	},
	{
		id: "ambiguityDecl",
		label: "Declaration vs multiplication",
		panes: "parse,sema",
		height: 380,
		code: `// X and Y could be both types like \`int\` / \`float\`
// or values like \`64\` / \`[20, 30]\`

void foo(alias X, alias Y)()
{
	X* Y;
	// 0 + X* Y;

	// foo!(X[Y]);
	int x = Y[2].init;
}

alias f = foo!(int, 3);
`,
	},
	{
		id: "structVsFunc",
		label: "Struct vs function literal",
		panes: "parse",
		height: 320,
		code: `// Sometimes the parser needs to look ahead pretty far to
// disambiguate a struct literal from a function literal

void bar()()
{
		auto y = { 1, 2, 3 };
		auto z = { 1, 2, 3; };

		// Because of the semicolon, 1, 2, 3 is parsed as a
		// 'comma expression', common in C but mostly disallowed to use in D,
		// though D's parser still recognizes it like any other expression.
}
`,
	},
	{
		id: "arrayInitVsAA",
		label: "Array initializer vs AA literal",
		panes: "parse",
		height: 320,
		code: `// Array initializers and Associative Array literals have the same grammar
// Yet they are separate AST nodes, and which is created depends on whether
// we are in a declaration with initializer vs. an assignment expression.

void foo()()
{
		int[2] x = [0: 10, 1: 20];
		x = [0: 10, 1: 20];
}
`,
	},
	{
		id: "parseVsSema",
		label: "Parse error vs semantic error",
		panes: "parse,diag",
		height: 320,
		code: `// Whether something is a parser/semantic error can be a bit arbitrary

void foo()()
{
	// Redundant storage classes are allowed per grammar,
 	// but the parser raises an error
	shared const shared int x = 0;

	// Cases outside a switch could be disallowed in the grammar,
	// but are a semantic error
	case 3:
}
`,
	},
	{
		id: "cycle",
		label: "Cyclic definitions",
		panes: "sema,diag",
		height: 240,
		code: `immutable x = y;
immutable y = z;
immutable z = x;
`,
	},
	{
		id: "resolvedCycle",
		label: "Resolved definitions",
		panes: "sema",
		height: 240,
		code: `immutable x = 0; // Now the type = int, and the rest resolves
immutable y = z;
immutable z = x;
`,
	},
	{
		id: "constFolding",
		label: "Constant folding",
		panes: "sema",
		height: 320,
		code: `// Initializers are constant folded
void f()
{
		string x = "abc" ~ "def"; // no GC allocations!
		int t = 3 * 9; // no runtime computation
}
`,
	},
	{
		id: "addrToSymOff",
		label: "AddrExp → SymOffExpr",
		panes: "sema",
		height: 320,
		code: `// AddrExp of array gets turned into a \`SymOffExpr\`
auto g(ref int[4] b) => &b[2];

struct S { int x, y; }

// But a struct field keeps \`AddrExp\`
auto h(ref S s) => &s.y;
`,
	},
	{
		id: "arrayBasis",
		label: "Array literal basis",
		panes: "sema",
		height: 320,
		code: `// As an optimization, array literals have a 'basis' element to
// reduce the number of lazy copies of each array element
immutable int[8] arr = 3;
`,
	},
	{
		id: "boundsCheck",
		label: "Array bounds check",
		panes: "ir",
		height: 360,
		code: `// This function calls _d_arraybounds_indexp(file, line, index, length)
// Because the backend uses binary trees, this list of 4 items is actually a pretty deep tree of OPParam pairs
auto f(int[] arr) => arr[0];
`,
	},
	{
		id: "stringSlicePair",
		label: "String slice (register pair)",
		panes: "ir",
		height: 360,
		code: `// A string is a char[], which is a 64-bit (length, ptr) pair that gets
// passed in 2 registers: (RDI RSI)
// In initial backend IR, this pair is represented as a 128-bit integer type

void f(ref string x)
{
		x = x.ptr[3 .. 5];
}

// This function is conceptually:
// *x = (length: 5 - 3, ptr: x.ptr + 3)

// But the backend IR expresses it as (redundant elems for side effects omitted):
// (*x = pair((*x >> 64) + 3, (5 - 3)))
`,
	},
];

export const EXAMPLES_BY_ID = Object.fromEntries(EXAMPLES.map((e) => [e.id, e]));
