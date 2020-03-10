
package:
@system int  gSystInt;
@safe   int  gSafeInt;
@system int* gSystPtr;
@safe   int* gSafePtr;

void main() @safe {

	//@safe int z;

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

	U u;
	cast(void) u.x;
	u.x = 3;
	cast(void) u.c;
	u.c = null;

	foreach(attr; __traits(getFunctionAttributes, x)) {
		pragma(msg, attr);
	}

	alias aliasToGlobal = gSystInt;
	aliasToGlobal++;
}

struct U {
	@system int x;
	@system char* c;
}

/+
void foo() @safe {
	U u;
	u.x = 3;
	*u.c = 3;
}
+/
