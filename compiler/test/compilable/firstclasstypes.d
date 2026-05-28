// REQUIRED_ARGS: -preview=firstClassTypes
// PERMUTE_ARGS:


// Prototype: first-class types via type_t (minimal slice).
// A ternary whose arms are types yields a value of type type_t,
// which constant-folds via CTFE so .sizeof works.

static assert((true  ? int : long).sizeof == 4);
static assert((false ? int : long).sizeof == 8);

// typeof a ternary-of-types is `type_t`
static assert(typeof(true ? int : long).stringof == "type_t");

// `.sizeof` also propagates through .stringof / .mangleof on wrapped type
static assert((true ? int : long).stringof == "int");
static assert((false ? int : long).stringof == "long");

// Slice 2: `type_t` as variable type
enum   type_t T = int;
static immutable type_t U = long;

static assert(T.sizeof == 4);
static assert(T.stringof == "int");
static assert(U.sizeof == 8);

// Ternary mixing `type_t` variables yields `type_t`
static assert((true  ? T : U).sizeof == 4);
static assert((false ? T : U).sizeof == 8);

// Slice 2: `type_t` as parameter and return type
type_t identity(type_t a) { return a; }
type_t pick(bool b, type_t a, type_t c) { return b ? a : c; }

static assert(identity(int).sizeof == 4);
static assert(identity(T).sizeof == 4);
static assert(pick(true,  int, long).sizeof == 4);
static assert(pick(false, int, long).sizeof == 8);

// Slice 3: `alias X = expr;` where expr is a ternary yielding `type_t`
enum bool is64bit = true;
alias size_t2 = is64bit ? ulong : uint;
alias size_t3 = is64bit ? uint : ubyte;

static assert(size_t2.sizeof == 8);
static assert(size_t2.stringof == "ulong");
static assert(size_t3.sizeof == 4);

// alias RHS can reference a `type_t` variable
alias A = true ? T : U;
static assert(A.sizeof == 4);
static assert(A.stringof == "int");

// alias RHS may be any `type_t`-valued expression: function call, array
// literal indexing, nested combinations.
type_t pickAlias(bool b) { return b ? int : long; }
alias B = pickAlias(true);
alias C = pickAlias(false);
static assert(B.sizeof == 4);
static assert(C.sizeof == 8);
static assert(B.stringof == "int");

alias D = [int, bool][0];
alias E = [int, bool][1];
static assert(D.sizeof == 4);
static assert(E.stringof == "bool");


// Slice 4: functions touching `type_t` skip codegen, so their bodies are
// only meaningful under CTFE. Define one that's never called from runtime
// code and confirm it still folds inside static asserts. If codegen ran,
// the object file would need a symbol for `firstIf`, which is fine to
// compile but here we additionally verify it composes via nested calls.
type_t firstIf(bool b, type_t a, type_t c) { return b ? a : c; }

static assert(firstIf(true,  int, long).sizeof == 4);
static assert(firstIf(false, int, long).sizeof == 8);

// Nested calls fold via CTFE
static assert(firstIf(true, firstIf(false, byte, short), int).sizeof == 2);
static assert(firstIf(false, byte, firstIf(true, long, int)).stringof == "long");

// Returning a literal type from a `type_t`-returning function
type_t alwaysInt() { return int; }
static assert(alwaysInt().sizeof == 4);
static assert(alwaysInt().stringof == "int");

// `type_t` parameter forwarded through a local `type_t` variable
type_t viaLocal(type_t a)
{
    type_t local = a;
    return local;
}
static assert(viaLocal(double).sizeof == 8);
static assert(viaLocal(byte).stringof == "byte");

// Deferred property lookup: `.sizeof` / `.stringof` on a `type_t` parameter
// resolves once the call substitutes the argument's TypeExp.
type_t largerType(type_t a, type_t b)
{
    return a.sizeof >= b.sizeof ? a : b;
}
static assert(largerType(int, long).sizeof == 8);
static assert(largerType(short, byte).sizeof == 2);
static assert(largerType(int, long).stringof == "long");
static assert(largerType(largerType(byte, short), int).sizeof == 4);

// Slice 5: `type_t[]` arrays, indexing, and alias-to-index
static immutable type_t[] types = [int, long, byte];
static assert(types.length == 3);
static assert(types[0].sizeof == 4);
static assert(types[1].sizeof == 8);
static assert(types[2].sizeof == 1);
static assert(types[0].stringof == "int");

// Static-immutable fixed-size array of `type_t`
static immutable type_t[3] arr = [int, long, byte];
static assert(arr[0].sizeof == 4);
static assert(arr[2].sizeof == 1);

// Array elements may be computed `type_t` expressions
static immutable type_t[] picked = [true ? int : long, false ? int : long];
static assert(picked[0].sizeof == 4);
static assert(picked[1].sizeof == 8);

// `alias` to an indexing of a `type_t` array
alias First = types[0];
static assert(First.sizeof == 4);
static assert(First.stringof == "int");

// Slice 6: `==` / `!=` on `type_t` values via mangle identity,
// and `__traits(toType, x.mangleof)` round-trip.
static assert(T == T);
static assert(T != U);
static assert((true ? T : U) == T);
static assert((false ? T : U) == U);

static assert(__traits(toType, T.mangleof) == T);
static assert(__traits(toType, (true ? T : U).mangleof) == T);

// Round-trip through a `type_t`-returning function
static assert(identity(int) == identity(int));
static assert(identity(int) != identity(long));
static assert(__traits(toType, identity(byte).mangleof) == identity(byte));

// Indexing a `type_t[]` participates in equality
static assert(arr[0] != arr[1]);
static assert(arr[0] == int);
static assert(__traits(toType, arr[2].mangleof) == arr[2]);

// Modifier sensitivity via alias-wrapped const
alias CI = const(int);
alias CI2 = const(int);
static assert(int != CI);
static assert(CI == CI2);

// Slice 7: `return <type expr>;` covering multiple branches, including
// returning `void` as a `type_t` value (not an empty return).
type_t unsignedOfSize(size_t n)
{
    if (n == 8)
        return ulong;
    if (n == 4)
        return uint;
    if (n == 2)
        return ushort;
    if (n == 1)
        return ubyte;

    return void;
}

static assert(unsignedOfSize(8).sizeof == 8);
static assert(unsignedOfSize(4).sizeof == 4);
static assert(unsignedOfSize(2).sizeof == 2);
static assert(unsignedOfSize(1).stringof == "ubyte");
static assert(unsignedOfSize(0).stringof == "void");
static assert(unsignedOfSize(0) == void);

type_t unsignedOf(type_t a)
{
    switch (a)
    {
        case long: return ulong;
        case int: return uint;
        case short: return ushort;
        case byte: return ubyte;
        default: assert(0);
    }
}

static assert(unsignedOf(short) == ushort);
