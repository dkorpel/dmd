/*
REQUIRED_ARGS: -o- -H -Hf${RESULTS_DIR}/compilable/testheader21806.di
OUTPUT_FILES: ${RESULTS_DIR}/compilable/testheader21806.di

TEST_OUTPUT:
---
=== ${RESULTS_DIR}/compilable/testheader21806.di
// D import file generated from 'compilable/testheader21806.d'
auto foo()
{
	return (() => 2)();
}
auto bar()
{
	return ()
	{
		return 3;
	}
	();
}
auto baz()
{
	()
	{
		int a;
		return 2;
	}
	();
}
---
*/

// https://github.com/dlang/dmd/issues/21806
// Invalid header generated for function literal

// Calling a lambda: () => 2() would parse as () => (2()), must be (() => 2)()
auto foo()
{
    return (() => 2)();
}

// Block-form single-statement: no parens needed, () { return 3; }() is valid
auto bar()
{
    return () { return 3; }();
}

// Block-form multi-statement: no parens needed
auto baz()
{
    () {
        int a;
        return 2;
    }();
}
