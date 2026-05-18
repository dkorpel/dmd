// REQUIRED_ARGS: -preview=firstClassTypes
// PERMUTE_ARGS:


// Prototype: first-class types via type_t (minimal slice).
// A ternary whose arms are types yields a value of type type_t,
// which constant-folds via CTFE so .sizeof works.

static assert((true  ? int : long).sizeof == 4);
static assert((false ? int : long).sizeof == 8);
static assert((true  ? byte : double).sizeof == 1);

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
