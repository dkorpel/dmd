/**
JSON parsing and escaping

Parses JSON text into the matching fields of a D struct, using the D lexer for tokenizing.

See_Also: https://www.json.org/
*/
module dmd.root.json;

import dmd.common.outbuffer;

/// Write `str` to `buf` as the contents of a JSON string, escaping characters that need it.
void writeJsonString(ref OutBuffer buf, const(char)[] str)
{
    foreach (c; str)
    {
        switch (c)
        {
            case '"':  buf.writestring(`\"`); break;
            case '\\': buf.writestring(`\\`); break;
            case '\b': buf.writestring(`\b`); break;
            case '\f': buf.writestring(`\f`); break;
            case '\n': buf.writestring(`\n`); break;
            case '\r': buf.writestring(`\r`); break;
            case '\t': buf.writestring(`\t`); break;
            default:
                if (cast(ubyte) c < 0x20)
                    buf.printf(`\u%04x`, cast(uint) cast(ubyte) c);
                else
                    buf.writeByte(cast(ubyte) c);
                break;
        }
    }
}

private int hexValue(char c) pure nothrow @nogc @safe
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

private int hex4(const(char)[] s) pure nothrow @nogc @safe
{
    if (s.length < 4)
        return -1;
    int v = 0;
    foreach (c; s[0 .. 4])
    {
        const d = hexValue(c);
        if (d < 0)
            return -1;
        v = v * 16 + d;
    }
    return v;
}

/// Parses json `text` and store the values in the matching fields of `result`.
void jsonParse(T, Sink)(ref T result, const(char)[] text, Sink eSink)
{
    import dmd.globals : global;
    import dmd.lexer : Lexer;
    import dmd.tokens : TOK, Token;

    /// Returns: whether you can access Token.intvalue from a token of `tok` kind
    static bool hasIntValue(TOK tok)
    {
        switch (tok)
        {
            case TOK.int32Literal, TOK.int64Literal, TOK.true_, TOK.false_:
                return true;
            default:
                return false;
        }
    }

    auto buffer = text ~ "\0\0\0\0";
    const end = buffer.ptr + text.length;
    auto lexer = new Lexer("json", buffer.ptr, 0, text.length, false, false, eSink, &global.compileEnv);
    const(char)[] stringValue;

    const(char)[] lexString()
    {
        auto p = lexer.p + 1;
        const start = p;
        while (p < end && *p != '"' && *p != '\\')
            p++;
        if (p < end && *p == '"')
        {
            lexer.p = p + 1;
            return start[0 .. p - start];
        }

        OutBuffer buf;
        buf.write(start[0 .. p - start]);
        while (true)
        {
            if (p >= end)
            {
                lexer.p = p;
                eSink.error(lexer.loc(), "Unterminated string while parsing `%.*s`", cast(int) text.length, text.ptr);
                break;
            }
            const c = *p++;
            if (c == '"')
                break;
            if (c != '\\')
            {
                buf.writeByte(c);
                continue;
            }
            const e = p < end ? *p++ : '\0';
            switch (e)
            {
                case '"':  buf.writeByte('"'); break;
                case '\\': buf.writeByte('\\'); break;
                case '/':  buf.writeByte('/'); break;
                case 'b':  buf.writeByte('\b'); break;
                case 'f':  buf.writeByte('\f'); break;
                case 'n':  buf.writeByte('\n'); break;
                case 'r':  buf.writeByte('\r'); break;
                case 't':  buf.writeByte('\t'); break;
                case 'u':
                    int cp = hex4(p[0 .. end - p]);
                    if (cp < 0)
                    {
                        lexer.p = p;
                        eSink.error(lexer.loc(), "Invalid `\\u` escape while parsing `%.*s`", cast(int) text.length, text.ptr);
                        break;
                    }
                    p += 4;
                    if (cp >= 0xD800 && cp <= 0xDBFF && end - p >= 6 && p[0] == '\\' && p[1] == 'u')
                    {
                        const lo = hex4(p[2 .. 6]);
                        if (lo >= 0xDC00 && lo <= 0xDFFF)
                        {
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                            p += 6;
                        }
                    }
                    if (cp >= 0xD800 && cp <= 0xDFFF)
                        cp = 0xFFFD;
                    buf.writeUTF8(cp);
                    break;
                default:
                    lexer.p = p;
                    eSink.error(lexer.loc(), "Invalid escape `\\%c` while parsing `%.*s`", e, cast(int) text.length, text.ptr);
                    break;
            }
        }
        lexer.p = p;
        return buf.extractSlice();
    }

    void popFront()
    {
        auto p = lexer.p;
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')
            p++;
        if (p >= end || *p != '"')
            return lexer.popFront();
        lexer.p = p;
        lexer.token.value = TOK.string_;
        stringValue = lexString();
    }

    popFront();

    /// Require a specific token, error if not present
    auto expect(TOK value)
    {
        if (lexer.front != value)
            eSink.error(lexer.scanloc, "Expected `%s`, got `%s` while parsing `%.*s`",
                Token.toChars(value), Token.toChars(lexer.front), cast(int) text.length, text.ptr);

        popFront();
    }

    /// Optionally lex a single token. If lexer points at `value`, pop it and return true.
    bool accepted(TOK value)
    {
        if (lexer.front == value)
        {
            popFront();
            return true;
        }
        return false;
    }

    // Parse a value of any shape without storing it, for unknown keys and type mismatches
    void skipValue()()
    {
        if (accepted(TOK.leftCurly))
        {
            if (accepted(TOK.rightCurly))
                return;

            while (!lexer.empty)
            {
                expect(TOK.string_);
                expect(TOK.colon);
                skipValue();
                if (!accepted(TOK.comma))
                    break;
            }
            expect(TOK.rightCurly);
        }
        else if (accepted(TOK.leftBracket))
        {
            if (accepted(TOK.rightBracket))
                return;

            while (!lexer.empty)
            {
                skipValue();
                if (!accepted(TOK.comma))
                    break;
            }
            expect(TOK.rightBracket);
        }
        else
        {
            if (!hasIntValue(lexer.front) && lexer.front != TOK.string_)
                eSink.error(lexer.scanloc, "Json value can't start with %s", Token.toChars(lexer.front));
            popFront();
        }
    }

    // Parse a json value into `destination`, recursing into struct fields.
    // Arrays are parsed into the same destination, so `[{"text": "x"}]` sets `destination.text`.
    void parseValue(V)(ref V destination)
    {
        if (accepted(TOK.leftBracket))
        {
            if (accepted(TOK.rightBracket))
                return;

            while (!lexer.empty)
            {
                static if (is(V == E[], E) && !is(V == string))
                {
                    E element;
                    parseValue(element);
                    destination ~= element;
                }
                else
                    parseValue(destination);
                if (!accepted(TOK.comma))
                    break;
            }
            expect(TOK.rightBracket);
            return;
        }

        static if (is(V == struct))
        {
            if (lexer.front != TOK.leftCurly)
                return skipValue(); // type mismatch: expected object, got int or string

            expect(TOK.leftCurly);
            if (accepted(TOK.rightCurly))
                return;

            while (!lexer.empty)
            {
                const key = lexer.front == TOK.string_ ? stringValue : null;
                expect(TOK.string_);
                expect(TOK.colon);
                parseMember(destination, key);
                if (!accepted(TOK.comma))
                    break;
            }
            expect(TOK.rightCurly);
        }
        else static if (is(V == string))
        {
            if (lexer.front != TOK.string_)
                return skipValue(); // type mismatch: expected string, got int or something
            destination = stringValue.idup;
            popFront();
        }
        else static if (is(V == E[], E))
        {
            return skipValue();
        }
        else static if (is(V : long))
        {
            if (!hasIntValue(lexer.front))
                return skipValue(); // type mismatch: expected int, got string or something
            destination = cast(V) lexer.token.intvalue;
            popFront();
        }
        else
            static assert(0, "unsupported field type `" ~ V.stringof ~ "`");
    }

    // Parse the value of `key` into the field of that name, skip it when there is no such field
    void parseMember(V)(ref V destination, const(char)[] key)
    {
        static foreach (member; __traits(allMembers, V))
        {
            if (key == member)
                return parseValue(__traits(getMember, destination, member));
        }
        skipValue();
    }

    parseValue(result);
}

unittest
{
    static struct Point { int x; int y; }
    static struct Shape { string name; Point pos; long id; }

    import dmd.errorsink : ErrorSinkNull;
    scope eSink = new ErrorSinkNull();
    Shape shape;
    jsonParse(shape, `{"name":"circle","unknown":[1,{"x":2}],"pos":{"x":3,"y":4},"id":5}`, eSink);
    assert(shape.name == "circle");
    assert(shape.pos.x == 3);
    assert(shape.pos.y == 4);
    assert(shape.id == 5);

    Shape mismatch;
    jsonParse(mismatch, `{"name":9,"pos":"str"}`, eSink);
    assert(mismatch.name is null);
    assert(mismatch.pos == Point.init);

    static struct Lists { string[] names; Point[] points; int single; }
    Lists lists;
    jsonParse(lists, `{"names":["a","b"],"points":[{"x":1},{"y":2}],"single":[3,4]}`, eSink);
    assert(lists.names == ["a", "b"]);
    assert(lists.points == [Point(1, 0), Point(0, 2)]);
    assert(lists.single == 4);

    Shape escaped;
    jsonParse(escaped, `{"name":"a\ud83d\ude00b\u00e9\\\u0041\/"}`, eSink);
    assert(escaped.name == "a\U0001F600bé\\A/", escaped.name);

    Shape unpaired;
    jsonParse(unpaired, `{"name":"\ud83dx\ude00", "id": 1}`, eSink);
    assert(unpaired.name == "\uFFFDx\uFFFD", unpaired.name);
    assert(unpaired.id == 1);

    Shape spaced;
    jsonParse(spaced, "{\n \"name\" :\t\"x\\ty\", \"q\\\"\": \"\\\"\", \"id\": 2}", eSink);
    assert(spaced.name == "x\ty");
    assert(spaced.id == 2);
}
