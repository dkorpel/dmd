/**
 * Lexer token dump for the wasm web app's "lexer" pane: render each source line
 * as the list of TOK enum member names of that line's tokens. Tokens carrying a
 * value (literals, identifiers) get that value as a parenthesized postfix,
 * e.g. float32Literal(3.5).
 */
module dmdwasm_lexdump;

import dmd.common.outbuffer : OutBuffer;
import dmd.globals : global;
import dmd.tokens : TOK;

// TOK value -> enum member name (e.g. TOK.add -> "add"), built at compile time.
private immutable string[TOK.max + 1] tokNames = () {
    string[TOK.max + 1] names;
    static foreach (member; __traits(allMembers, TOK))
        names[__traits(getMember, TOK, member)] = member;
    return names;
}();

// True for tokens that carry user data worth showing as a parenthesized postfix
// (numeric/char/string literals and identifiers). Keywords/punctuation don't.
private bool tokenHasValue(TOK v)
{
    switch (v)
    {
    case TOK.int32Literal, TOK.uns32Literal, TOK.int64Literal, TOK.uns64Literal,
         TOK.int128Literal, TOK.uns128Literal,
         TOK.float32Literal, TOK.float64Literal, TOK.float80Literal,
         TOK.imaginary32Literal, TOK.imaginary64Literal, TOK.imaginary80Literal,
         TOK.charLiteral, TOK.wcharLiteral, TOK.dcharLiteral, TOK.wchar_tLiteral,
         TOK.identifier, TOK.string_, TOK.hexadecimalString, TOK.interpolated:
        return true;
    default:
        return false;
    }
}

/// Lex `src` (NUL-terminated, `len` bytes before the NUL) and fill `buf` with
/// one line per source line listing that line's token enum names.
void dumpTokens(ref OutBuffer buf, const(char)* fileName, const(char)* src, size_t len)
{
    import dmd.lexer : Lexer;
    import dmd.tokens : Token;

    buf.reset();
    scope lexer = new Lexer(fileName, src, 0, len, false, false, global.errorSinkNull, null);

    uint curLine = 1;
    bool atLineStart = true;
    lexer.nextToken();
    while (lexer.token.value != TOK.endOfFile)
    {
        const L = lexer.token.loc.linnum;
        while (curLine < L)
        {
            buf.writeByte('\n');
            curLine++;
            atLineStart = true;
        }
        if (!atLineStart)
            buf.writeByte(' ');
        buf.writestring(tokNames[lexer.token.value]);
        if (tokenHasValue(lexer.token.value))
        {
            buf.writeByte('(');
            lexer.token.toString((ubyte c) { buf.writeByte(c); });
            buf.writeByte(')');
        }
        atLineStart = false;
        lexer.nextToken();
    }
    buf.writeByte('\n');
}
