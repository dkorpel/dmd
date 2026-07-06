// String building via append and int-to-string conversion.
// Stresses StringExp handling and array reallocation; typical of code
// generators that build source with string mixins.
module string_build;

string itoa(long v)
{
    if (v == 0)
        return "0";
    string s;
    bool neg = v < 0;
    if (neg)
        v = -v;
    while (v > 0)
    {
        s = cast(char)('0' + v % 10) ~ s;
        v /= 10;
    }
    return neg ? "-" ~ s : s;
}

string generate(int n)
{
    string code;
    foreach (i; 0 .. n)
    {
        code ~= "int member" ~ itoa(i) ~ " = " ~ itoa(i * i) ~ ";\n";
    }
    return code;
}

enum result = generate(3000);
static assert(result.length > 0);
