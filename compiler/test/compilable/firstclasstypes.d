// REQUIRED_ARGS: -preview=firstClassTypes
// PERMUTE_ARGS:

// ternary of types → type_t; .sizeof / .stringof on result; typeof is type_t
static assert((true  ? int : long).sizeof == 4);
static assert((false ? int : long).sizeof == 8);
static assert((true  ? int : long).stringof == "int");
static assert(typeof(true ? int : long).stringof == "type_t");

// type_t variable (enum and immutable)
enum   type_t T = int;
static immutable type_t U = long;
static assert(T.sizeof == 4);
static assert(U.sizeof == 8);

// type_t as function parameter, return type, and local variable
type_t pick(bool b, type_t a, type_t c) { return b ? a : c; }
static assert(pick(true,  int, long).sizeof == 4);
static assert(pick(false, int, long).sizeof == 8);

type_t viaLocal(type_t a) { type_t local = a; return local; }
static assert(viaLocal(int).sizeof == 4);

// property access (.sizeof) on a type_t parameter
type_t larger(type_t a, type_t b) { return a.sizeof >= b.sizeof ? a : b; }
static assert(larger(int, long).sizeof == 8);
static assert(larger(int, long).stringof == "long");

// alias RHS: ternary, function call, array-literal index
alias A = true ? T : U;
static assert(A.sizeof == 4);

alias B = pick(true, int, long);
static assert(B.stringof == "int");

alias C = [int, bool][0];
static assert(C.sizeof == 4);

// type_t[] array: length and indexing
static immutable type_t[] types = [int, long, byte];
static assert(types.length == 3);
static assert(types[0].sizeof == 4);
static assert(types[2].stringof == "byte");

// equality / inequality; __traits(toType, mangleof) round-trip; qualifier sensitivity
static assert(T == T);
static assert(T != U);
static assert(__traits(toType, T.mangleof) == T);
alias CI = const(int);
static assert(int != CI);

// if-chain returning type_t, including void as a value
type_t unsignedOfSize(size_t n)
{
    if (n == 4) return uint;
    if (n == 1) return ubyte;
    return void;
}
static assert(unsignedOfSize(4) == uint);
static assert(unsignedOfSize(0) == void);

// switch on type_t
type_t unsignedOf(type_t a)
{
    switch (a)
    {
        case int:  return uint;
        case long: return ulong;
        default: assert(0);
    }
}
static assert(unsignedOf(int) == uint);

// recursive CTFE with type_t[] concatenation
type_t[] integralChain(type_t a)
{
    switch (a)
    {
        case byte:  return [ubyte, short] ~ integralChain(short);
        case short: return [ushort, int];
        default: return [];
    }
}
static assert(integralChain(byte).length == 4);
static assert(integralChain(byte)[2] == ushort);
