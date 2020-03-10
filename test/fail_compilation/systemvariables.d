
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

void introspection() @safe {
	@system int x;
	static assert(__traits(getFunctionAttributes, x)[0] == "@system");
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

/+
void foo() @safe {
	U u;
	u.x = 3;
	*u.c = 3;
}
+/
