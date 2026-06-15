/*
TEST_OUTPUT:
---
fail_compilation/staticassert_sema1.d(21): Error: static assert:  "unsupported OS"
fail_compilation/staticassert_sema1.d(24): Error: module `object` import `_NONEXISTENT` not found
fail_compilation/staticassert_sema1.d(25): Error: module `object` import `_NONEXISTENT` not found
fail_compilation/staticassert_sema1.d(26): Error: module `object` import `_NONEXISTENT` not found
---
*/

// https://issues.dlang.org/show_bug.cgi?id=24645
// Test that a static assert(0) is reported before subsequent import errors,
// rather than being drowned out by them.

version(_NONEXISTENT_OS)
{

}
else
{
    static assert(0, msg);
}

import object: _NONEXISTENT;
import object: _NONEXISTENT;
import object: _NONEXISTENT;

enum msg = "unsupported OS";
