/**
Implements dmd as a languag server, following the Language Server Protocol (LSP)

Provides 'hover' and 'go to definition' support for variables.

See_Also: https://microsoft.github.io/language-server-protocol/
*/
module dmd.lsp;

// dmd -main -unittest -i -J../.. -Jdmd/res -run dmd/lsp.d
// bdmdd && cat ../test/testlspinput.txt | dmdd -lsp
// echo -e "Content-Length: 49\r\n\r\n{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"id\":1}" | nc -U /tmp/lsp-socket

import core.stdc.stdio;
import dmd.aggregate;
import dmd.ast_node;
import dmd.common.outbuffer;
import dmd.dclass;
import dmd.declaration;
import dmd.dmodule;
import dmd.dstruct;
import dmd.dsymbol;
import dmd.dsymbolsem;
import dmd.dtemplate;
import dmd.errorsink;
import dmd.expression;
import dmd.func;
import dmd.globals;
import dmd.identifier;
import dmd.lexer;
import dmd.location;
import dmd.typesem : Type_init;
import dmd.root.filename;
import dmd.root.string;
import dmd.rootobject;
import dmd.semantic2;
import dmd.semantic3;
import dmd.target;
import dmd.tokens;
import dmd.visitor;


struct Lsp
{
    // dmd.globals.Param params;

    /// In-memory document store: URI -> content (kept in sync via textDocument/did* notifications)
    string[string] openDocuments;
}


extern(C++) class LspVisitor : SemanticTimeTransitiveVisitor
{
    alias visit = typeof(super).visit;

    int line;
    int column;
    ASTNode result;

    this(int line, int column)
    {
        this.line = line;
        this.column = column;
    }

    bool inLoc(Loc loc, Identifier ident)
    {
        if (!loc.isValid)
            return false;
        // fprintf(stderr, "[!] checking %s at %s\n", ident.toChars, loc.toChars);
        // fprintf(stderr, "[!] line %d ?= %d, col = %d > %d\n", this.line, sl.line, this.column, sl.column);
        auto sl = SourceLoc(loc);
        const endCol = sl.column + ident.toString().length;
        return (this.line == sl.line && this.column >= sl.column && this.column <= endCol);
    }

    override void visit(StructDeclaration d)
    {
        if (inLoc(d.loc, d.ident))
            this.result = d;
        super.visit(d);
    }

    override void visit(FuncDeclaration d)
    {
        if (inLoc(d.loc, d.ident))
            this.result = d;
        super.visit(d);
    }

    override void visit(ClassDeclaration d)
    {
        if (inLoc(d.loc, d.ident))
            this.result = d;
        super.visit(d);
    }

    override void visit(VarDeclaration d)
    {
        if (inLoc(d.loc, d.ident))
            this.result = d;
    }

    override void visit(VarExp e)
    {
        if (inLoc(e.loc, e.var.ident))
            this.result = e;
    }
}

/// Find the AST node under the object
ASTNode findCursorObject(ref Lsp lsp, Params params)
{
    {
        Type_init();
        Module._init();
        Loc._init();
    }

    SourceLoc sl = toSourceLoc(params.textDocument.uri, params.position);
    const(char)[] p = FileName.name(sl.filename); // strip path
    auto ext = FileName.ext(sl.filename);
    p = p[0 .. $ - ext.length - 1];
    Loc loc = Loc.singleFilename(sl.filename.ptr);
    auto id = Identifier.idPool(p);
    // fprintf(stderr, "loc = %s\n", loc.toChars);
    Module m = new Module(loc, sl.filename, id, /*ddoc*/ true, false);

    // Use in-memory content if available (avoids reading unsaved file from disk)
    if (auto content = params.textDocument.uri in lsp.openDocuments)
        m.src = cast(const(ubyte)[]) (*content ~ "\0\0\0\0");

    if (!m.read(loc))
    {
        fprintf(stderr, "[!] read erorrs!\n");
        return null;
    }
    m = m.parse();
    if (!m)
    {
        fprintf(stderr, "[!] parse erorrs!\n");
        return null;
    }
    m.importedFrom = m;
    m.importAll(null);
    m.dsymbolSemantic(null);
    m.semantic2(null);
    m.semantic3(null);

    scope visitor = new LspVisitor(sl.line, sl.column);
    visitor.visit(m);


    {
        Type_init();
        Module.deinitialize();
        FuncDeclaration.lastMain = null;

        // global.deinitialize();
        // target.deinitialize();
        // Expression.deinitialize();
        // Dsymbol.deinitialize();
    }

    return visitor.result;
}

int lspMain()
{
    import core.stdc.stdlib : atoi;
    import core.vararg;

    class ErrorSinkLsp : ErrorSinkNull
    {
        OutBuffer result;
        int errors = 0;
        extern(C++): override:

        void verror(Loc loc, const(char)* format, va_list ap)
        {
            result.reset();
            result.printf("Error (%d): ", loc.charnum);
            result.vprintf(format, ap);
            result.writestring("\n");
            if (errors++ < 10)
                fprintf(stderr, "%s", result.extractChars);
        }

        void verrorSupplemental(Loc loc, const(char)* format, va_list ap)
        {
            result.vprintf(format, ap);
            result.writestring("\n");
        }
    }

    Lsp lsp;
    scope eSink = new ErrorSinkLsp();
    // scope eSink = new ErrorSinkNull;

    char[] buffer = new char[16 * 1024];

    while (!feof(stdin))
    {
        buffer[] = '\0';
        int contentLength = 0;
        while (fgets(buffer.ptr, cast(int) buffer.length, stdin))
        {
            enum cl = "Content-Length:";
            auto line = buffer.ptr.toDString();
            if (line.startsWith(cl))
                contentLength = atoi(buffer.ptr + cl.length);

            if (line.startsWith("\r\n"))
                break; // end of header
        }

        // Fill buffer up to contentLength
        if (contentLength > buffer.length)
            buffer.length = contentLength;
        char[] json = buffer[0 .. contentLength];
        size_t totalRead = 0;
        while (totalRead < json.length)
        {
            size_t n = fread(json.ptr + totalRead, char.sizeof, json.length - totalRead, stdin);
            if (n == 0)
            {
                if (ferror(stdin))
                {
                    import core.stdc.errno;
                    eSink.error(Loc.initial, "errno = %d", errno);
                    return errno;
                }
                break; // EOF mid-message
            }
            totalRead += n;
        }

        // fprintf(stderr, "[!] Content length = %d\n", cast(int) contentLength);
        fprintf(stderr, "[!] Content = %.*s\n", cast(int) json.length, json.ptr);
        JsonRpc result;
        jsonParse(result, json, eSink);
        fprintf(stderr, "[!] Responding to %.*s\n", cast(int) result.method.length, result.method.ptr);
        lspRespond(lsp, result);
    }
    return 0;
}

void lspRespond(ref Lsp lsp, JsonRpc result)
{
    OutBuffer buf;
    buf.printf(`{"jsonrpc":"2.0","id":%d,"result":`, result.id);

    if (result.method == "initialize")
    {
        buf.writestring(`{"capabilities":{
            "definitionProvider":true,
            "hoverProvider":true,
            "textDocumentSync":1
            }}`);
    }
    else if (result.method == "textDocument/definition")
    {
        if (auto obj = findCursorObject(lsp, result.params))
        {
            fprintf(stderr, obj);

            if (auto d = obj.isDeclaration())
            {

            }
            if (auto e = obj.isExpression())
            {
                if (auto ve = e.isVarExp())
                {
                    Declaration v = ve.var;
                    SourceLoc sl = SourceLoc(v.loc);
                    buf.printf(
                        `{"uri":"file://%s","range":{"start":{"line": %d,"character": %d},"end":{"line": %d,"character": %d}}}`,
                        sl.filename.ptr, sl.line - 1, sl.column - 1, sl.line - 1, sl.column
                    );
                }
            }
        }
        else
            buf.printf("null");
    }
    else if (result.method == "textDocument/hover")
    {
        // fprintf(stderr, "[!] found! %s", v.toChars);
        if (auto obj = findCursorObject(lsp, result.params))
        {
            buf.printf(`{"contents":{"kind":"markdown","value":"`);

            OutBuffer hover;
            if (auto e = isExpression(obj))
            {
                if (auto ve = e.isVarExp())
                {
                    if (auto vd = ve.var)
                    {
                        if (auto comment = vd.comment)
                            hover.printf("%s\n\n", vd.comment);
                    }
                }
                hover.printf("**type**: %s\n", e.type.toChars);
            }
            else if (auto d = isDsymbol(obj))
            {
                if (auto sd = d.isStructDeclaration())
                {
                    // hover.printf(`type: %s`, d.type.toChars);
                    hover.printf("**sizeof**: %d\n", cast(int) sd.size(Loc.initial));
                }
                if (auto cd = d.isClassDeclaration())
                {
                    hover.printf("**classInstanceSize**: %d\n", cast(int) cd.size(Loc.initial));
                }
                if (auto fd = d.isFuncDeclaration())
                {
                    hover.printf("**type**: %s\n", fd.type.toChars);
                }
                if (auto vd = d.isVarDeclaration())
                {

                    hover.printf("**type**: %s\n\n", vd.type.toChars);
                    if (auto ei = vd._init ? vd._init.isExpInitializer() : null)
                    {
                        hover.printf("**init**: %s\n", ei.exp.toChars);
                    }
                }
            }

            // buf.printf(`{"contents":{"kind":"markdown","value":"**int**\n\nEH?."},`
            //     ~`"range": {"start": { "line": 0, "character": 1 },"end": { "line": 0, "character": 3 }}}`, );
            buf.writeJsonString(hover.extractSlice);
            buf.printf(`"}}`);
        }
        else
        {
            buf.printf("null");
        }
    }
    else if (result.method == "textDocument/completion")
    {
        // auto-complete
    }
    else if (result.method == "textDocument/signatureHelp")
    {
        // show parameters when opening a f() for a function call
    }
    else if (result.method == "textDocument/publishDiagnostics")
    {
        // show errors
    }
    else if (result.method == "textDocument/documentSymbol")
    {
        // list functions, types, variables in a file
    }
    else if (result.method == "textDocument/didOpen")
    {
        lsp.openDocuments[result.params.textDocument.uri] = result.params.textDocument.text;
        return; // notification, no response
    }
    else if (result.method == "textDocument/didChange")
    {
        // textDocumentSync: Full (1) — contentChanges[0].text is the complete new content
        lsp.openDocuments[result.params.textDocument.uri] = result.params.contentChanges.text;
        return; // notification, no response
    }
    else if (result.method == "textDocument/didClose")
    {
        lsp.openDocuments.remove(result.params.textDocument.uri);
        return; // notification, no response
    }
    else if (result.method == "textDocument/didSave")
    {
        return; // content already up to date from didChange; no response needed
    }
    else if (result.method == "initialized")
    {
        return; // Not required to respond
    }
    else
    {
        fprintf(stderr, "[!] unknown method %.*s\n", result.method.fTuple.expand);
        buf.printf("null");
    }

    buf.printf(`}`);
    // fprintf(stderr, "[!] send response of length %d: %s\n", cast(int) buf.length, buf.peekChars());
    printf("Content-Length: %d\r\n\r\n", cast(int) buf.length);
    printf("%s", buf.extractChars());
    fflush(stdout);
}

void writeJsonString(ref OutBuffer buf, const(char)[] str)
{
    foreach (c; str)
        writeCharLiteral(c, &buf.put);
        //buf.writeCharLiteral(c);
}

/// Returns: whether you can access Token.intvalue from a token of `tok` kind
bool hasIntValue(TOK tok)
{
    switch (tok)
    {
        case TOK.int32Literal, TOK.int64Literal, TOK.string_, TOK.true_, TOK.false_:
            return true;
        default:
            return false;
    }
}

/// Parses json `text` and store the values inthe matching fields of `result`.
JsonRpc jsonParse(ref JsonRpc result, const(char)[] text, ErrorSink eSink)
{
    auto lexer = new Lexer("json", (text ~ "\0\0\0\0").ptr, 0, text.length, false, false, eSink, &global.compileEnv);
    lexer.popFront(); // Pop the 'reserved' token
    const(char)[][] keys = [];

    // Example: setPrimary(obj, ["pos", "x"], Token(3))
    // Means we want to set: obj.pos.x = 3
    // Returns: whether we found and set the field
    bool setPrimary(T)(ref T destination, const(char)[][] keys, const ref Token token)
    {
        static if (is(T == struct))
        {
            if (keys.length == 0)
                return false; // type mismatch: expected object, got int or string

            foreach (member; __traits(allMembers, T))
            {
                if (keys[0] == member)
                    return setPrimary(__traits(getMember, destination, member), keys[1 .. $], token);
            }
            return false; // field not found
        }
        else
        {
            if (keys.length != 0)
                return false; // type mismatch: expected simple value, got object

            static if (is(T == string))
            {
                if (token.value != TOK.string_)
                    return false; // type mismatch: expected string, got int or something
                destination = token.ustring.toDString.idup;
            }
            else static if (is(T : long))
            {
                if (!hasIntValue(token.value))
                    return false; // type mismatch: expected int, got string or something
                destination = cast(T) token.intvalue;
            }
            else
                static assert(0, "unsupported field type `" ~ T.stringof ~ "`");

            return true;
        }
    }

    // Parse primary expression, number or string
    void primary()
    {
        if (!hasIntValue(lexer.front) && !lexer.front == TOK.string_)
            eSink.error(lexer.scanloc, "Json value can't start with %s", Token.toChars(lexer.front));
        else
            setPrimary(result, keys, lexer.token);

        lexer.popFront();
    }

    /// Require a specific token, error if not present
    auto expect(TOK value)
    {
        if (lexer.front != value)
            eSink.error(lexer.scanloc, "Expected `%s`, got `%s` while parsing `%.*s`",
                Token.toChars(value), Token.toChars(lexer.front), cast(int) text.length, text.ptr);

        auto res = lexer.token;
        lexer.popFront();
        return res;
    }

    /// Optionally lex a single token. If lexer points at `value`, pop it and return true.
    bool accepted(TOK value)
    {
        if (lexer.front == value)
        {
            lexer.popFront();
            return true;
        }
        return false;
    }

    // Parse JSON array, e.g. [{}, "x", 5]
    void array()()
    {
        expect(TOK.leftBracket);
        if (accepted(TOK.rightBracket))
            return;


        for (size_t i = 0; !lexer.empty; i++)
        {
            anyValue();
            if (!accepted(TOK.comma))
                break;
        }
        expect(TOK.rightBracket);
    }

    // Parse JSON key-value pair, e.g. "key": 3
    void keyValue()()
    {
        auto key = expect(TOK.string_);
        keys ~= key.ustring.toDString; // push field on the stack
        expect(TOK.colon);
        anyValue();
        keys = keys[0 .. $ - 1]; // pop field from stack
    }

    void obj()()
    {
        expect(TOK.leftCurly);
        if (accepted(TOK.rightCurly))
            return;

        while (!lexer.empty)
        {
            keyValue();
            if (!accepted(TOK.comma))
                break;
        }
        expect(TOK.rightCurly);
    }

    void anyValue()()
    {
        if (lexer.front == TOK.leftCurly)
            obj();
        else if (lexer.front == TOK.leftBracket)
            array();
        else
            primary();
    }

    obj();
    return result;
}

// struct and field names match JsonRPC / LSP protocol
struct JsonRpc
{
    int id;
    string method;
    Params params;
}

struct Params
{
    Uri textDocument;
    Position position;
    string rootPath; // main folder that is open in editor
    ContentChange contentChanges; // maps contentChanges[0].text for textDocument/didChange

    // struct Capabilities
    // {
    //     struct TextDocument {}
    //     TextDocument textDocument;
    // }
    // Capabilities capabilities;
}

struct Uri
{
    string uri;
    string text; // populated in textDocument/didOpen
}

struct ContentChange
{
    Range range; // changed range (for textDocumentSync Incremental mode)
    string text; // full new content (textDocumentSync Full mode)
}

struct Position
{
    int line;
    int character;
}

struct Range
{
    Position start;
    Position end;
}

SourceLoc toSourceLoc(string uri, Position position)
{
    SourceLoc result;
    if (uri.startsWith("file://"))
        result.filename = uri["file://".length .. $];

    result.line = position.line + 1; // 0-based
    result.column = position.character + 1; // 0-based
    return result;
}

unittest
{
    scope eSink = new ErrorSinkStderr();
    JsonRpc result;
    jsonParse(result, `
    {
        "jsonrpc": "2.0",
        "id": 1,
        "array": [],
        "method": "textDocument/definition",
        "params": {
            "textDocument": { "uri": "file:///path/to/file" },
            "position": { "line": 10, "character": 5 }
        }
    }`, eSink);

    assert(result.id == 1);
    assert(result.method == "textDocument/definition");
    assert(result.params.textDocument.uri == "file:///path/to/file");
    assert(result.params.position.line == 10);
    assert(result.params.position.character == 5);

    writeln(result);

    string initialize = `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":20036,"clientInfo":{"name":"Sublime Text LSP","version":"2.3.0"},"rootUri":"file:///home/dennis/repos/dmd","rootPath":"/home/dennis/repos/dmd","workspaceFolders":[{"name":"dmd","uri":"file:///home/dennis/repos/dmd"}],"capabilities":{"general":{"regularExpressions":{"engine":"ECMAScript"},"markdown":{"parser":"Python-Markdown","version":"3.2.2"}},"textDocument":{"synchronization":{"dynamicRegistration":true,"didSave":true,"willSave":true,"willSaveWaitUntil":true},"hover":{"dynamicRegistration":true,"contentFormat":["markdown","plaintext"]},"completion":{"dynamicRegistration":true,"completionItem":{"snippetSupport":true,"deprecatedSupport":true,"documentationFormat":["markdown","plaintext"],"tagSupport":{"valueSet":[1]},"resolveSupport":{"properties":["detail","documentation","additionalTextEdits"]},"insertReplaceSupport":true,"insertTextModeSupport":{"valueSet":[2]},"labelDetailsSupport":true},"completionItemKind":{"valueSet":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25]},"insertTextMode":2,"completionList":{"itemDefaults":["editRange","insertTextFormat","data"]}},"signatureHelp":{"dynamicRegistration":true,"contextSupport":true,"signatureInformation":{"activeParameterSupport":true,"documentationFormat":["markdown","plaintext"],"parameterInformation":{"labelOffsetSupport":true}}},"references":{"dynamicRegistration":true},"documentHighlight":{"dynamicRegistration":true},"documentSymbol":{"dynamicRegistration":true,"hierarchicalDocumentSymbolSupport":true,"symbolKind":{"valueSet":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26]},"tagSupport":{"valueSet":[1]}},"documentLink":{"dynamicRegistration":true,"tooltipSupport":true},"formatting":{"dynamicRegistration":true},"rangeFormatting":{"dynamicRegistration":true,"rangesSupport":true},"declaration":{"dynamicRegistration":true,"linkSupport":true},"definition":{"dynamicRegistration":true,"linkSupport":true},"typeDefinition":{"dynamicRegistration":true,"linkSupport":true},"implementation":{"dynamicRegistration":true,"linkSupport":true},"codeAction":{"dynamicRegistration":true,"codeActionLiteralSupport":{"codeActionKind":{"valueSet":["quickfix","refactor","refactor.extract","refactor.inline","refactor.rewrite","source.fixAll","source.organizeImports"]}},"dataSupport":true,"isPreferredSupport":true,"resolveSupport":{"properties":["edit"]}},"rename":{"dynamicRegistration":true,"prepareSupport":true,"prepareSupportDefaultBehavior":1},"colorProvider":{"dynamicRegistration":true},"publishDiagnostics":{"relatedInformation":true,"tagSupport":{"valueSet":[1,2]},"versionSupport":true,"codeDescriptionSupport":true,"dataSupport":true},"diagnostic":{"dynamicRegistration":true,"relatedDocumentSupport":true},"selectionRange":{"dynamicRegistration":true},"foldingRange":{"dynamicRegistration":true,"foldingRangeKind":{"valueSet":["comment","imports","region"]}},"codeLens":{"dynamicRegistration":true},"inlayHint":{"dynamicRegistration":true,"resolveSupport":{"properties":["textEdits","label.command"]}},"semanticTokens":{"dynamicRegistration":true,"requests":{"range":true,"full":{"delta":true}},"tokenTypes":["namespace","type","class","enum","interface","struct","typeParameter","parameter","variable","property","enumMember","event","function","method","macro","keyword","modifier","comment","string","number","regexp","operator","decorator","label"],"tokenModifiers":["declaration","definition","readonly","static","deprecated","abstract","async","modification","documentation","defaultLibrary"],"formats":["relative"],"overlappingTokenSupport":false,"multilineTokenSupport":true,"augmentsSyntaxTokens":true},"callHierarchy":{"dynamicRegistration":true},"typeHierarchy":{"dynamicRegistration":true}},"workspace":{"applyEdit":true,"didChangeConfiguration":{"dynamicRegistration":true},"executeCommand":{},"workspaceEdit":{"documentChanges":true,"failureHandling":"abort"},"workspaceFolders":true,"symbol":{"dynamicRegistration":true,"resolveSupport":{"properties":["location.range"]},"symbolKind":{"valueSet":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26]},"tagSupport":{"valueSet":[1]}},"configuration":true,"codeLens":{"refreshSupport":true},"inlayHint":{"refreshSupport":true},"semanticTokens":{"refreshSupport":true},"diagnostics":{"refreshSupport":true}},"window":{"showDocument":{"support":true},"showMessage":{"messageActionItem":{"additionalPropertiesSupport":true}},"workDoneProgress":true}},"initializationOptions":{}}}`;
    jsonParse(result, initialize, eSink);

    // textDocument/didOpen: params.textDocument.text contains the full file content
    JsonRpc didOpen;
    jsonParse(didOpen, `{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///foo.d","languageId":"d","version":1,"text":"module foo;\nint x = 5;\n"}}}`, eSink);
    assert(didOpen.method == "textDocument/didOpen");
    assert(didOpen.params.textDocument.uri == "file:///foo.d");
    assert(didOpen.params.textDocument.text == "module foo;\nint x = 5;\n");

    // textDocument/didChange: contentChanges[0].text is the full new content (Full sync)
    JsonRpc didChange;
    jsonParse(didChange, `{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///foo.d","version":2},"contentChanges":[{"text":"module foo;\nint x = 42;\n"}]}}`, eSink);
    assert(didChange.method == "textDocument/didChange");
    assert(didChange.params.textDocument.uri == "file:///foo.d");
    assert(didChange.params.contentChanges.text == "module foo;\nint x = 42;\n");
}
