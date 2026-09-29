module imports.ctfe_table;

struct SCE { uint x; }

SCE table(size_t i)
{
    static immutable uint[] t = x"01010101 02020202 03030303";
    return SCE(t[i]);
}
