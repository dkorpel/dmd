/**
Test that `dmd -lsp` produces correct hover output for a variable declaration.

Sends a minimal LSP session (initialize → initialized → textDocument/hover)
and asserts the response contains the expected type and initializer.
*/
import dshell;
import std.algorithm : canFind;
import std.conv : to;

int main()
{
    // Absolute path to the D source file the hover request targets
    const testFile = absolutePath(buildPath(EXTRA_FILES, "lsp", "hover_test.d"));
    const uri = "file://" ~ testFile;

    // Minimal LSP messages — hover targets 'answer' at line 2 char 4 in hover_test.d:
    //   line 0: module hover_test;
    //   line 1: (empty)
    //   line 2: int answer = 42;
    //                ^char 4
    const msgs = [
        `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":1,"capabilities":{}}}`,
        `{"jsonrpc":"2.0","method":"initialized","params":{}}`,
        `{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"` ~ uri ~ `"},"position":{"line":2,"character":4}}}`,
    ];

    // Build LSP-framed input (RFC: Content-Length header + blank line + JSON body)
    string input;
    foreach (msg; msgs)
        input ~= "Content-Length: " ~ to!string(msg.length) ~ "\r\n\r\n" ~ msg;

    // Run dmd -lsp with input piped through stdin, capture stdout
    auto pipes = pipeProcess([DMD(), "-lsp"], Redirect.stdin | Redirect.stdout);
    pipes.stdin.write(input);
    pipes.stdin.close();

    string output;
    foreach (line; pipes.stdout.byLine(KeepTerminator.yes))
        output ~= line;
    wait(pipes.pid);

    // The hover response for VarDeclaration 'int answer = 42' must contain:
    //   **type**: int      (from vd.type.toChars)
    //   **init**: 42       (from the ExpressionInitializer)
    assert(output.canFind(`**type**: int`),
        "Expected hover to contain '**type**: int', got:\n" ~ output);
    assert(output.canFind(`**init**: 42`),
        "Expected hover to contain '**init**: 42', got:\n" ~ output);

    writeln("LSP hover test passed");
    return 0;
}
