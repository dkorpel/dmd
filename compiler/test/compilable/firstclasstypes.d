// REQUIRED_ARGS: -preview=firstClassTypes
// PERMUTE_ARGS:

static assert((true ? int : long).sizeof == 4);
static assert((false ? int : long).sizeof == 8);

enum type_t T = int;
static immutable type_t U = long;
static assert(T.sizeof == 4);
static assert(U.sizeof == 8);

type_t viaLocal(type_t a)
{
    type_t local = a;
    return local;
}

static assert(viaLocal(int).sizeof == 4);

type_t larger(type_t a, type_t b)
{
    return a.sizeof >= b.sizeof ? a : b;
}

static assert(larger(int, long).stringof == "long");

static immutable type_t[] types = [int, long, byte];
static assert(types.length == 3);
static assert(types[0].sizeof == 4);
static assert(types[2].stringof == "byte");

static assert(T == T);
static assert(T != U);
static assert(__traits(toType, T.mangleof) == T);
alias CI = const(int);
static assert(int != CI);

type_t unsignedOfSize(size_t n)
{
    if (n == 4)
        return uint;
    if (n == 1)
        return ubyte;
    return void;
}

static assert(unsignedOfSize(4) == uint);
static assert(unsignedOfSize(0) == void);

// switch on type_t
type_t unsignedOf(type_t a)
{
    switch (a)
    {
    case int: return uint;
    case long: return ulong;
    default:
        assert(0);
    }
}

static assert(unsignedOf(int) == uint);

// recursive CTFE with type_t[] concatenation
type_t[] integralChain(type_t a)
{
    switch (a)
    {
    case byte: return [ubyte, short] ~ integralChain(short);
    case short: return [ushort, int];
    default:
        return [];
    }
}

static assert(integralChain(byte).length == 4);
static assert(integralChain(byte)[2] == ushort);

type_t f() => [void[3], void[], void*][0];
static assert(f().stringof == "void[3]");

// Breaking change: this used to equal `typeof(0 ? short.init : ubyte.init)` = `int`
static assert(typeof(0 ? short : ubyte) == ubyte);

//
enum typemap = [int: uint, short: ushort, byte: ubyte, long: ulong];
static assert(typemap[int] == uint);
static assert(typemap[short] == ushort);

// `in` on a type_t-keyed AA yields a pointer to the value, like a regular AA
static assert(int in typemap);
static assert(!(float in typemap));
static assert(*(int in typemap) == uint);

type_t[] assignElems()
{
    type_t[] arr = [int, float];
    arr[0] = bool;
    return arr;
}

static assert(assignElems()[0] == bool);

type_t[] expandLen()
{
    type_t[] arr;
    arr ~= long;
    arr.length = 3;
    return arr;
}

static assert(expandLen().length == 3);
static assert(expandLen()[0] == long);
static assert(expandLen()[1] == void); // new elements filled with type_t.init = void

// type_t.init = void (the simplest type, analogous to null pointer)
void test(T)()
{
    static assert(is(T == type_t));
    T x = T.init; // was ICE: null returned from defaultInit
    static assert(is(typeof(x) == type_t));
}

void testTemplate()
{
    test!type_t();
}
