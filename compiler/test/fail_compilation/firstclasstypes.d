/*
REQUIRED_ARGS: -preview=firstClassTypes
TEST_OUTPUT:
---
fail_compilation/firstclasstypes.d(19): Error: cannot take address of CTFE-only function `firstIf` (signature uses `type_t`)
fail_compilation/firstclasstypes.d(20): Error: cannot take address of CTFE-only function `alwaysInt` (signature uses `type_t`)
fail_compilation/firstclasstypes.d(23): Error: `type_t` value `int` cannot be used in arithmetic
fail_compilation/firstclasstypes.d(24): Error: `type_t` value `int` cannot be used in arithmetic
fail_compilation/firstclasstypes.d(26): Error: `type_t` value `int` cannot be used in arithmetic
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
