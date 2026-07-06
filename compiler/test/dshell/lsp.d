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
    // Completion without a leading `.` lists module-level types and functions
    {
        name: "completion-module-scope",
        source: "module comp_glob;\n\nstruct Point { int x; }\nenum Color { red }\nint area() { return 1; }\nvoid main() {\n    \n}\n",
        script: (ref c) { c.completion(6, 4); },
        expected: [`"label":"Point","kind":22`, `"label":"Color","kind":13`, `"label":"area","kind":3`],
    },
    // textDocument/signatureHelp currently emits a hard-coded signature
    {
        name: "signatureHelp-stub",
        source: "module sig_test;\n\nvoid f() {}\n",
        script: (ref c) { c.signatureHelp(2, 0); },
        expected: [`"label":"exampleFunc(`, `"activeSignature":0`, `"activeParameter":0`],
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
    // didChange reanalyzes: the error from didOpen disappears once the
    // document is edited to something valid (exercises repeated analysis)
    {
        name: "diagnostics-didchange",
        source: "module diag_change;\n\nint x = undefinedSymbol;\n",
        script: (ref c) { c.didChange("module diag_change;\n\nint x = 1;\n"); },
        expected: [`undefined identifier`, `"diagnostics":[]`],
    },
];

// ----------------------------------------------------------------------------
// LSP test framework
// ----------------------------------------------------------------------------

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
