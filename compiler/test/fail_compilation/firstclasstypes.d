/*
REQUIRED_ARGS: -preview=firstClassTypes
TEST_OUTPUT:
---
fail_compilation/firstclasstypes.d(25): Error: `type_t` value `int` cannot be used in arithmetic
fail_compilation/firstclasstypes.d(26): Error: `type_t` value `int` cannot be used in arithmetic
fail_compilation/firstclasstypes.d(28): Error: `type_t` value `int` cannot be used in arithmetic
---
*/





type_t firstIf(bool b, type_t a, type_t c) { return b ? a : c; }
type_t alwaysInt() { return int; }

enum type_t T = int;

// Cannot take address of CTFE-only `type_t` functions.
enum addr1 = &firstIf;
enum addr2 = &alwaysInt;

// Arithmetic on `type_t` values is nonsensical.
enum a = int + 3;
enum b = 3 - int;

enum d = T + 1;
