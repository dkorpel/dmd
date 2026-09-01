/**
Tests for `dmd -lsp` (Language Server Protocol).

Each test case spawns a fresh `dmd -lsp`, drives it through a scripted
client session, then asserts on the captured server output.

To add a case, append to `cases` below: give it a name, the D source
the server should see, a delegate that sends the requests, and a list
of substrings expected in the server's output.
*/
module test.dshell.lsp;

import dshell;

import std.algorithm : canFind;
import std.array : appender;
import std.conv : to;
import std.format : format;
import std.json : JSONValue;

int main()
{
    int failed;
    foreach (ref c; cases)
    {
        try
        {
            runCase(c);
            writefln("LSP test passed: %s", c.name);
        }
        catch (Throwable t)
        {
            writefln("LSP test FAILED: %s\n%s", c.name, t.msg);
            failed++;
        }
    }
    return failed == 0 ? 0 : 1;
}

// ----------------------------------------------------------------------------
// Test cases
// ----------------------------------------------------------------------------

struct Case
{
    string name;
    string source;
    void delegate(ref LspClient) script;
    string[] expected;
}

immutable Case[] cases = [
    // textDocument/hover on a VarDeclaration
    {
        name: "hover-vardecl",
        source: "module hover_test;\n\nint answer = 42;\n",
        script: (ref c) { c.hover(2, 4); },
        expected: [`**type**: int`, `**init**: 42`],
    },
    // textDocument/hover on a FuncDeclaration
    {
        name: "hover-funcdecl",
        source: "module hover_func;\n\nvoid greet() {}\n",
        script: (ref c) { c.hover(2, 5); },
        expected: [`**type**: void()`],
    },
    // textDocument/definition jumps from a use site to the declaration
    {
        name: "definition-funcall",
        source: "module def_test;\n\nint foo() { return 1; }\nvoid main() { foo(); }\n",
        script: (ref c) { c.definition(3, 14); },
        expected: [`"uri":"file://`, `"line":2`, `"character":4`],
    },
    // textDocument/definition on a member access jumps to the field declaration
    {
        name: "definition-field",
        source: "module def_field;\n\nstruct S { int field; }\nvoid main() { S s; s.field = 3; }\n",
        script: (ref c) { c.definition(3, 21); },
        expected: [`"uri":"file://`, `"line":2`, `"character":15`],
    },
    // textDocument/definition on a type name jumps to the type declaration
    {
        name: "definition-type",
        source: "module def_type;\n\nstruct Other { int x; }\nvoid main() { Other o; }\n",
        script: (ref c) { c.definition(3, 15); },
        expected: [`"uri":"file://`, `"line":2`, `"character":7`],
    },
    // Member completion after `s.` lists the struct's fields and methods,
    // even though `s.` at the end of a block is incomplete source
    {
        name: "completion-member",
        source: "module comp_test;\n\nstruct S { int field; void method() {} }\nvoid main() {\n    S s;\n    s.\n}\n",
        script: (ref c) { c.completion(5, 6); },
        expected: [`"label":"field","kind":5`, `"label":"method","kind":2`],
    },
    // Member completion also offers module-level functions callable via UFCS
    {
        name: "completion-ufcs",
        source: "module comp_ufcs;\n\nstruct V { int x; }\nint scaled(V v, int f) { return v.x * f; }\nint other(int i) { return i; }\nvoid main() {\n    V v;\n    v.\n}\n",
        script: (ref c) { c.completion(7, 6); },
        expected: [`"label":"x","kind":5`, `"label":"scaled","kind":3`],
    },
    // `this.` completes to the enclosing aggregate's members
    {
        name: "completion-this",
        source: "module comp_this;\n\nstruct S\n{\n    int field;\n    void m()\n    {\n        this.\n    }\n}\n",
        script: (ref c) { c.completion(7, 13); },
        expected: [`"label":"field","kind":5`, `"label":"m","kind":2`],
    },
    // A type name before the `.` completes to its members (enum members here)
    {
        name: "completion-enum-type",
        source: "module comp_enum;\n\nenum E { one, two }\nvoid main() {\n    E.\n}\n",
        script: (ref c) { c.completion(4, 6); },
        expected: [`"label":"one","kind":20`, `"label":"two","kind":20`],
    },
    // Types nested inside aggregates are found too
    {
        name: "completion-nested-enum",
        source: "module comp_nested;\n\nstruct S { enum E { one } }\nvoid main() {\n    S.E.\n}\n",
        script: (ref c) { c.completion(4, 8); },
        expected: [`"label":"one","kind":20`],
    },
    // Static members of a struct offered after the type name
    {
        name: "completion-type-static",
        source: "module comp_static;\n\nstruct M { enum one = 1; static int two() { return 2; } }\nvoid main() {\n    M.\n}\n",
        script: (ref c) { c.completion(4, 6); },
        expected: [`"label":"one"`, `"label":"two"`],
    },
    // A `.` after a non-identifier (like `]`) offers nothing rather than
    // falling back to module-level symbols
    {
        name: "completion-baredot",
        source: "module comp_baredot;\n\nvoid main() {\n    int[3] a;\n    a[0].\n}\n",
        script: (ref c) { c.completion(4, 9); },
        expected: [`"items":[]`],
    },
    // Completion without a leading `.` lists module-level types and functions
    {
        name: "completion-module-scope",
        source: "module comp_glob;\n\nstruct Point { int x; }\nenum Color { red }\nint area() { return 1; }\nvoid main() {\n    \n}\n",
        script: (ref c) { c.completion(6, 4); },
        expected: [`"label":"Point","kind":22`, `"label":"Color","kind":13`, `"label":"area","kind":3`],
    },
    // textDocument/signatureHelp resolves the enclosing call; cursor is on
    // the second argument
    {
        name: "signatureHelp-call",
        source: "module sig_test;\n\nint add(int x, int y) { return x + y; }\nvoid main() { add(1, 2); }\n",
        script: (ref c) { c.signatureHelp(3, 21); },
        expected: [`"label":"add(int x, int y)"`, `"activeParameter":1`],
    },
    // All overloads are listed; activeSignature picks the arity that fits
    {
        name: "signatureHelp-overloads",
        source: "module sig_ovl;\n\nvoid f(int x) {}\nvoid f(int x, int y) {}\nvoid main() { f(1, 2); }\n",
        script: (ref c) { c.signatureHelp(4, 19); },
        expected: [`"label":"f(int x)"`, `"label":"f(int x, int y)"`, `"activeSignature":1`, `"activeParameter":1`],
    },
    // Method call through a struct instance
    {
        name: "signatureHelp-method",
        source: "module sig_method;\n\nstruct S { int scale(int factor) { return factor; } }\nvoid main() { S s; s.scale(2); }\n",
        script: (ref c) { c.signatureHelp(3, 27); },
        expected: [`"label":"scale(int factor)"`, `"activeParameter":0`],
    },
    // UFCS call: the receiver is the signature's first parameter, so
    // activeParameter skips past it
    {
        name: "signatureHelp-ufcs",
        source: "module sig_ufcs;\n\nstruct V { int x; }\nint scaled(V v, int f) { return v.x * f; }\nvoid main() { V v; v.scaled(2); }\n",
        script: (ref c) { c.signatureHelp(4, 28); },
        expected: [`"label":"scaled(V v, int f)"`, `"activeParameter":1`],
    },
    // Outside any call, no signatures are offered
    {
        name: "signatureHelp-nocall",
        source: "module sig_none;\n\nvoid f() {}\n",
        script: (ref c) { c.signatureHelp(2, 0); },
        expected: [`"signatures":[]`],
    },
    // unittest bodies are analyzed too (-lsp implies -unittest)
    {
        name: "signatureHelp-unittest",
        source: "module sig_ut;\n\nint tw(int x) { return x; }\nunittest { int y = tw(1); }\n",
        script: (ref c) { c.signatureHelp(3, 22); },
        expected: [`"label":"tw(int x)"`, `"activeParameter":0`],
    },
    // Parameter storage classes appear in the signature labels
    {
        name: "signatureHelp-ref",
        source: "module sig_ref;\n\nvoid f(ref int x, float y) {}\nvoid main() { int a; f(a, 1); }\n",
        script: (ref c) { c.signatureHelp(3, 26); },
        expected: [`"label":"f(ref int x, float y)"`, `"label":"ref int x"`, `"activeParameter":1`],
    },
    // A struct literal call shows the fields as parameters
    {
        name: "signatureHelp-structliteral",
        source: "module sig_lit;\n\nstruct P { int x; float y; }\nvoid main() { P p = P(1, 2); }\n",
        script: (ref c) { c.signatureHelp(3, 25); },
        expected: [`"label":"P(int x, float y)"`, `"activeParameter":1`],
    },
    // A struct constructor call shows the constructor named after the struct
    {
        name: "signatureHelp-ctor",
        source: "module sig_ctor;\n\nstruct C { int a; this(int a, int b) { this.a = a + b; } }\nvoid main() { auto c = C(1, 2); }\n",
        script: (ref c) { c.signatureHelp(3, 25); },
        expected: [`"label":"C(int a, int b)"`, `"activeParameter":0`],
    },
    // textDocument/documentSymbol returns a hierarchical symbol tree
    {
        name: "documentSymbol-tree",
        source: "module docsym;\n\nstruct S { int field; void method() {} }\nint gvar;\nvoid gfunc() {}\nenum E { a, b }\n",
        script: (ref c) { c.documentSymbol(); },
        expected: [`"name":"S","kind":23`, `"name":"field","kind":8`, `"name":"method","kind":6`,
                   `"name":"gvar","kind":13`, `"name":"gfunc","kind":12`, `"name":"E","kind":10`,
                   `"name":"a","kind":22`, `"children":[`],
    },
    // Module-level `@safe:` / `private` wrap declarations in AttribDeclarations;
    // documentSymbol looks through them
    {
        name: "documentSymbol-attrib",
        source: "module docsym_attrib;\n@safe:\n\nprivate enum N = 3;\nvoid f() {}\n",
        script: (ref c) { c.documentSymbol(); },
        expected: [`"name":"N","kind":13`, `"name":"f","kind":12`],
    },
    // Constructors appear as `this` with the Constructor kind
    {
        name: "documentSymbol-ctor",
        source: "module docsym_ctor;\n\nstruct C { int a; this(int a) { this.a = a; } }\n",
        script: (ref c) { c.documentSymbol(); },
        expected: [`"name":"this","kind":9`],
    },
    // Go-to-definition on a struct literal jumps to the struct
    {
        name: "definition-structliteral",
        source: "module def_lit;\n\nstruct P { int x; float y; }\nvoid main() { P p = P(1, 2); }\n",
        script: (ref c) { c.definition(3, 20); },
        expected: [`"line":2`, `"character":7`],
    },
    // textDocument/references lists the declaration and every use in the file
    {
        name: "references-var",
        source: "module refs_test;\n\nint x;\nvoid main() { x = 1; int y = x + x; }\n",
        script: (ref c) { c.references(2, 4); },
        expected: [`{"line":2,"character":4}`, `{"line":3,"character":14}`,
                   `{"line":3,"character":29}`, `{"line":3,"character":33}`],
    },
    // A UFCS use site is found and its range points at the identifier, not the dot
    {
        name: "references-ufcs",
        source: "module refs_ufcs;\n\nstruct V { int x; }\nint norm(V v) { return v.x; }\nvoid main() { V v; int n = v.norm(); }\n",
        script: (ref c) { c.references(3, 5); },
        expected: [`{"line":3,"character":4}`, `{"line":4,"character":29}`],
    },
    // references works from a use site and finds method calls by identity
    {
        name: "references-method",
        source: "module refs_method;\n\nstruct S { void go() {} }\nvoid main() { S s; s.go(); s.go(); }\n",
        script: (ref c) { c.references(3, 21); },
        expected: [`{"line":2,"character":16}`, `{"line":3,"character":21}`, `{"line":3,"character":29}`],
    },
    // publishDiagnostics is pushed from didOpen; the error here should surface
    {
        name: "diagnostics-error",
        source: "module diag_err;\n\nint x = undefinedSymbol;\n",
        script: (ref c) {},
        expected: [`"method":"textDocument/publishDiagnostics"`, `undefined identifier`, `"severity":1`],
    },
    // A clean source publishes an empty diagnostics array
    {
        name: "diagnostics-clean",
        source: "module diag_ok;\n\nint x = 1;\n",
        script: (ref c) {},
        expected: [`"method":"textDocument/publishDiagnostics"`, `"diagnostics":[]`],
    },
    {
        name: "diagnostics-cap",
        source: manyErrors(),
        script: (ref c) {},
        expected: [`too many diagnostics, further messages suppressed`],
    },
    // didChange reanalyzes: the error from didOpen disappears once the
    // document is edited to something valid (exercises repeated analysis)
    {
        name: "diagnostics-didchange",
        source: "module diag_change;\n\nint x = undefinedSymbol;\n",
        script: (ref c) { c.didChange("module diag_change;\n\nint x = 1;\n"); },
        expected: [`undefined identifier`, `"diagnostics":[]`],
    },
    // A method called without an explicit `this.` is still found, with the
    // range on the identifier rather than the call's parenthesis
    {
        name: "references-implicit-this",
        source: "module refs_impthis;\n\nclass C\n{\n    void act() {}\n    void step() { act(); }\n}\n",
        script: (ref c) { c.references(4, 9); },
        expected: [`{"line":4,"character":9}`, `{"line":5,"character":18}`],
    },
    // Enum member uses are constant-folded out of the AST; the fold hook
    // still records them (initializer, comparison, case label), and the
    // cursor resolves on a folded use site
    {
        name: "references-enum-member",
        source: "module refs_enum;\n\nenum E { one, two }\nE g = E.one;\nvoid f()\n{\n    E l = E.two;\n    if (l == E.one) {}\n    switch (l) { case E.one: break; default: break; }\n}\n",
        script: (ref c) { c.references(7, 16); },
        expected: [`{"line":2,"character":9}`, `{"line":3,"character":8}`,
                   `{"line":7,"character":15}`, `{"line":8,"character":24}`],
    },
    // Manifest constant uses survive constant folding too
    {
        name: "references-manifest",
        source: "module refs_manifest;\n\nenum dt = 2;\nint f() { return dt + dt; }\n",
        script: (ref c) { c.references(2, 5); },
        expected: [`{"line":2,"character":5}`, `{"line":3,"character":17}`,
                   `{"line":3,"character":22}`],
    },
    // From the constructor declaration: the decl range spans `this` and a
    // `new C(...)` use points at the class name
    {
        name: "references-ctor-new",
        source: "module refs_ctor;\n\nclass C\n{\n    this(int a) {}\n}\nvoid f() { auto c = new C(1); }\n",
        script: (ref c) { c.references(4, 4); },
        expected: [`"start":{"line":4,"character":4},"end":{"line":4,"character":8}`,
                   `"start":{"line":6,"character":24},"end":{"line":6,"character":25}`],
    },
    // Go-to-definition on `new C` jumps to the constructor
    {
        name: "definition-new",
        source: "module def_new;\n\nclass C\n{\n    this(int a) {}\n}\nvoid f() { auto c = new C(1); }\n",
        script: (ref c) { c.definition(6, 24); },
        expected: [`"line":4`, `"character":4`],
    },
    // References on a struct include struct literal calls
    {
        name: "references-structliteral",
        source: "module refs_slit;\n\nstruct P { int x; }\nvoid f() { P p = P(3); }\n",
        script: (ref c) { c.references(2, 7); },
        expected: [`{"line":2,"character":7}`, `{"line":3,"character":17}`],
    },
    // A parameter is found from its declaration in the signature
    {
        name: "references-param",
        source: "module refs_param;\n\nint f(int abc) { return abc * abc; }\n",
        script: (ref c) { c.references(2, 10); },
        expected: [`{"line":2,"character":10}`, `{"line":2,"character":24}`,
                   `{"line":2,"character":30}`],
    },
    // A foreach variable's declaration location is the variable name,
    // not the `foreach` keyword
    {
        name: "references-foreach-var",
        source: "module refs_feach;\n\nvoid f()\n{\n    int[3] a;\n    foreach (v; a) { int y = v; }\n}\n",
        script: (ref c) { c.references(5, 13); },
        expected: [`{"line":5,"character":13}`, `{"line":5,"character":29}`],
    },
    // A statement after an error in a nested block keeps its analysis
    {
        name: "definition-after-nested-error",
        source: "module refs_err;\n\nint g() { return 3; }\nvoid f()\n{\n    if (true)\n    {\n        auto e = undefinedXYZ;\n        int y = g();\n    }\n}\n",
        script: (ref c) { c.definition(8, 16); },
        expected: [`"line":2`, `"character":4`],
    },
    // References on a struct include type names written in declarations
    {
        name: "references-type-use",
        source: "module refs_type;\n\nstruct Vec { int x; }\nVec add(Vec a) { Vec r; return r; }\n",
        script: (ref c) { c.references(2, 7); },
        expected: [`{"line":2,"character":7}`, `{"line":3,"character":0}`,
                   `{"line":3,"character":8}`, `{"line":3,"character":17}`],
    },
    // Go-to-definition on an enum type name written in a declaration
    {
        name: "definition-enum-type-use",
        source: "module def_enumtype;\n\nenum State { IDLE, BUSY }\nvoid f() { State s; }\n",
        script: (ref c) { c.definition(3, 11); },
        expected: [`"line":2`, `"character":5`],
    },
    // References on a type used for static member access `G.f()`
    {
        name: "references-type-static-access",
        source: "module refs_statictype;\n\nstruct G { static int f(int x) { return x; } }\nvoid h() { int y = G.f(1); }\n",
        script: (ref c) { c.references(2, 7); },
        expected: [`{"line":2,"character":7}`, `{"line":3,"character":19}`],
    },
    // References on a static member function called via the type name
    {
        name: "references-static-member-call",
        source: "module refs_staticfn;\n\nstruct G { static int f(int x) { return x; } }\nvoid h() { int y = G.f(1); }\n",
        script: (ref c) { c.references(2, 22); },
        expected: [`{"line":2,"character":22}`, `{"line":3,"character":21}`],
    },
    // The body of a foreach whose aggregate has errors stays navigable
    {
        name: "references-error-foreach",
        source: "module refs_errfeach;\n\nint g(int x) { return x; }\nvoid f()\n{\n    int total;\n    foreach (v; noSuchThing) { total = g(total); }\n}\n",
        script: (ref c) { c.references(5, 8); },
        expected: [`{"line":5,"character":8}`, `{"line":6,"character":31}`,
                   `{"line":6,"character":41}`],
    },
    // Uses of the error-typed loop variable itself are found
    {
        name: "references-error-foreach-var",
        source: "module refs_errfvar;\n\nvoid f()\n{\n    foreach (num; noSuchThing) { int y = num + num; }\n}\n",
        script: (ref c) { c.references(4, 13); },
        expected: [`{"line":4,"character":13}`, `{"line":4,"character":41}`,
                   `{"line":4,"character":47}`],
    },
    // The callee of a call whose arguments have errors is still a reference,
    // also through an assignment whose left-hand side has errors
    {
        name: "references-callee-error-args",
        source: "module refs_errcall;\n\nstruct G { static int f(int x) { return x; } }\nvoid h()\n{\n    foreach (num; noSuchThing) { num.member = G.f(num.val); }\n}\n",
        script: (ref c) { c.references(2, 22); },
        expected: [`{"line":2,"character":22}`, `{"line":5,"character":48}`],
    },
    // Completion on a function parameter's members
    {
        name: "completion-param",
        source: "module comp_param;\n\nstruct P { int health; void jump() {} }\nvoid f(P p)\n{\n    p.jump();\n}\n",
        script: (ref c) { c.completion(5, 6); },
        expected: [`"label":"health"`, `"label":"jump"`],
    },
    // Completion on a dangling `p.` at the end of a block while editing
    {
        name: "completion-dangling-dot",
        source: "module comp_dangle;\n\nstruct P { int health; void jump() {} }\nvoid f(P p)\n{\n    p.\n}\n",
        script: (ref c) { c.completion(5, 6); },
        expected: [`"label":"health"`, `"label":"jump"`],
    },
    // A dangling `p.` followed by more statements doesn't swallow them
    {
        name: "recovery-dangling-dot-next-stmt",
        source: "module rec_dangle;\n\nstruct P { int health; void jump() {} }\nvoid f(P p)\n{\n    p.\n    int x = 5;\n    p.jump();\n}\n",
        script: (ref c) { c.references(6, 8); c.definition(7, 6); },
        expected: [`{"line":6,"character":8}`, `"line":2,"character":28`],
    },
    // An unreadable import doesn't abort analysis of the rest of the module
    {
        name: "recovery-bad-import",
        source: "module rec_import;\n\nimport doesnotexist;\n\nstruct Item { int num; }\nvoid use()\n{\n    Item i;\n    i.num = 3;\n}\n",
        script: (ref c) { c.definition(8, 7); },
        expected: [`"line":4,"character":18`],
    },
    // An unclosed call paren doesn't swallow the following function, and
    // signatureHelp still resolves the callee on both sides
    {
        name: "signaturehelp-unclosed-call",
        source: "module sig_unclosed;\n\nvoid take(int count, string label) {}\nvoid caller()\n{\n    take(\n}\nvoid caller2()\n{\n    take(1, \"a\");\n}\n",
        script: (ref c) { c.signatureHelp(5, 9); c.signatureHelp(9, 12); },
        expected: [`take(int count, string label)`, `"activeParameter":1`],
    },
    // The callee of a call that fails overload resolution stays navigable
    {
        name: "definition-callee-bad-args",
        source: "module def_badargs;\n\nvoid take(int count, string label) {}\nvoid caller()\n{\n    take(1);\n}\n",
        script: (ref c) { c.definition(5, 5); },
        expected: [`"line":2,"character":5`],
    },
    // Gagged speculative errors (foreach range rewrite attempts) don't leak
    // into diagnostics or break foreach over ranges
    {
        name: "completion-range-foreach",
        source: "module comp_range;\n\nstruct D { int id; void dig() {} }\nstruct R { D[] items; bool empty() { return true; } D front() { return items[0]; } void popFront() {} }\nR all() { return R(); }\nvoid f()\n{\n    foreach (o; all())\n    {\n        o.dig();\n    }\n}\n",
        script: (ref c) { c.completion(9, 10); },
        expected: [`"label":"id"`, `"label":"dig"`],
    },
];

// ----------------------------------------------------------------------------
// LSP test framework
// ----------------------------------------------------------------------------

string manyErrors()
{
    string s = "module diag_cap;\n";
    foreach (i; 0 .. 1500)
        s ~= format("int x%d = undefined%d;\n", i, i);
    return s;
}

void runCase(ref const Case tc)
{
    auto client = LspClient.start(tc.name, tc.source);
    tc.script(client);
    string output = client.finish();
    foreach (needle; tc.expected)
        assert(output.canFind(needle),
            format("[%s] expected to find:\n  %s\nin output:\n%s",
                tc.name, needle, output));
}

/**
Drives a `dmd -lsp` subprocess with framed LSP messages.

Lifecycle: `start` spawns the server and runs initialize → didOpen so the
case starts with a known document; the script delegate then sends whatever
requests the case needs; `finish` closes stdin and returns captured stdout.
*/
struct LspClient
{
    private ProcessPipes pipes;
    private int nextId = 1;
    private string uri;
    private string sourcePath;

    static LspClient start(string caseName, string source)
    {
        // Write the source to a per-case file so the server can resolve `file://` URIs.
        const dir = buildPath(Vars.OUTPUT_BASE, "lsp");
        if (!exists(dir))
            mkdirRecurse(dir);
        const path = buildPath(dir, caseName ~ ".d");
        std.file.write(path, source);

        LspClient c;
        c.sourcePath = path;
        c.uri = "file://" ~ path;
        c.pipes = pipeProcess([DMD(), "-lsp"], Redirect.stdin | Redirect.stdout);

        c.request("initialize", `{"processId":1,"capabilities":{}}`);
        c.notify("initialized", `{}`);
        c.notify("textDocument/didOpen", format(
            `{"textDocument":{"uri":"%s","languageId":"d","version":1,"text":%s}}`,
            c.uri, jsonEscape(source)));
        return c;
    }

    // textDocument/hover at (line, character) — both 0-based, per LSP.
    void hover(int line, int character)
    {
        request("textDocument/hover", positionParams(line, character));
    }

    void definition(int line, int character)
    {
        request("textDocument/definition", positionParams(line, character));
    }

    void completion(int line, int character)
    {
        request("textDocument/completion", positionParams(line, character));
    }

    void signatureHelp(int line, int character)
    {
        request("textDocument/signatureHelp", positionParams(line, character));
    }

    void documentSymbol()
    {
        request("textDocument/documentSymbol", format(`{"textDocument":{"uri":"%s"}}`, uri));
    }

    void references(int line, int character)
    {
        request("textDocument/references", positionParams(line, character));
    }

    // Replace the document's content (textDocumentSync Full)
    void didChange(string newText)
    {
        notify("textDocument/didChange", format(
            `{"textDocument":{"uri":"%s","version":2},"contentChanges":[{"text":%s}]}`,
            uri, jsonEscape(newText)));
    }

    private string positionParams(int line, int character)
    {
        return format(
            `{"textDocument":{"uri":"%s"},"position":{"line":%d,"character":%d}}`,
            uri, line, character);
    }

    // Send a request that expects a response (assigns an id).
    int request(string method, string paramsJson)
    {
        const id = nextId++;
        writeMessage(format(
            `{"jsonrpc":"2.0","id":%d,"method":"%s","params":%s}`,
            id, method, paramsJson));
        return id;
    }

    // Send a notification (no id, no response expected).
    void notify(string method, string paramsJson)
    {
        writeMessage(format(
            `{"jsonrpc":"2.0","method":"%s","params":%s}`,
            method, paramsJson));
    }

    private void writeMessage(string body_)
    {
        pipes.stdin.writef("Content-Length: %d\r\n\r\n%s", body_.length, body_);
        pipes.stdin.flush();
    }

    /// Close stdin so the server exits cleanly, then drain and return stdout.
    string finish()
    {
        pipes.stdin.close();
        auto buf = appender!string;
        foreach (line; pipes.stdout.byLine(KeepTerminator.yes))
            buf.put(line);
        wait(pipes.pid);
        return buf.data;
    }
}

/// Encode `s` as a JSON string literal (including surrounding quotes).
private string jsonEscape(string s)
{
    return JSONValue(s).toString();
}
