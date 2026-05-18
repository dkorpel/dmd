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
