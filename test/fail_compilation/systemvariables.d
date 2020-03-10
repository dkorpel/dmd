/*
REQUIRED_ARGS: -preview=systemvariables
TEST_OUTPUT:
---
fail_compilation/systemvariables.d(23): Error: cannot modify @system variable `gSystInt` in @safe code
fail_compilation/systemvariables.d(25): Error: cannot access @system variable `gSystPtr` of unsafe type in @safe code
fail_compilation/systemvariables.d(25): Error: cannot modify @system variable `gSystPtr` in @safe code
fail_compilation/systemvariables.d(28): Error: cannot modify @system variable `systInt` in @safe code
fail_compilation/systemvariables.d(30): Error: cannot access @system variable `systPtr` of unsafe type in @safe code
fail_compilation/systemvariables.d(30): Error: cannot modify @system variable `systPtr` in @safe code
fail_compilation/systemvariables.d(37): Error: variable `systPtr` with unsafe type cannot be read from in `@safe` code
fail_compilation/systemvariables.d(40): Error: variable `systInt` is marked @system and cannot be written to in `@safe` code
fail_compilation/systemvariables.d(40): Error: cannot modify @system variable `u0.systInt` in @safe code
fail_compilation/systemvariables.d(42): Error: variable `systPtr` is marked @system and cannot be written to in `@safe` code
fail_compilation/systemvariables.d(42): Error: cannot modify @system variable `u0.systPtr` in @safe code
fail_compilation/systemvariables.d(60): Error: cannot modify @system variable `gSystInt` in @safe code
---
*/

// https://github.com/dlang/DIPs/pull/179
package:
@system int  gSystInt;
@safe   int  gSafeInt;
@system int* gSystPtr;
@safe   int* gSafePtr;

void basic() @safe {
	@system int  systInt;
	@safe   int  safeInt;
	@system int* systPtr;
	@safe   int* safePtr;

	gSafeInt = 0;
	gSystInt = 0;
	gSafePtr = null;
	gSystPtr = null;

	safeInt = 0;
	systInt = 0;
	safePtr = null;
	systPtr = null;
}

void aggregate() @safe {
	U u0;
	cast(void) u0.systInt;
	cast(void) u0.safeInt;
	cast(void) u0.systPtr;
	cast(void) u0.safePtr;

	u0.systInt = 0;
	u0.safeInt = 0;
	u0.systPtr = null;
	u0.safePtr = null;

	U u1;
	u1 = u0; // allowed
}

struct U {
	@system int  systInt;
	@safe   int  safeInt;
	@system int* systPtr;
	@safe   int* safePtr;
}

enum int* x = cast(int*) 3;
alias aliasToSystInt = gSystInt;

void indirect() @safe {
	aliasToSystInt++;
	*x = 3;
}
