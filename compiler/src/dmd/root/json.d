/**
JSON parsing and escaping

Parses JSON text into the matching fields of a D struct, using the D lexer for tokenizing.

See_Also: https://www.json.org/
*/
module dmd.root.json;

import dmd.common.outbuffer;
import dmd.root.string;

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

    auto lexer = new Lexer("json", (text ~ "\0\0\0\0").ptr, 0, text.length, false, false, eSink, &global.compileEnv);
    lexer.popFront(); // Pop the 'reserved' token

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
            lexer.popFront();
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
                const key = expect(TOK.string_).ustring.toDString;
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
            destination = lexer.token.ustring.toDString.idup;
            lexer.popFront();
        }
        else static if (is(V : long))
        {
            if (!hasIntValue(lexer.front))
                return skipValue(); // type mismatch: expected int, got string or something
            destination = cast(V) lexer.token.intvalue;
            lexer.popFront();
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
}
