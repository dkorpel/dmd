

@system int globalInt;
@system int* globalPtr;

void main() @safe {
	//@safe int z;

	alias aliasToGlobal = globalInt;
	aliasToGlobal++;

	U u;
	cast(void) u.x;
	u.x = 3;
	cast(void) u.c;
	u.c = null;

	foreach(attr; __traits(getFunctionAttributes, x)) {
		pragma(msg, attr);
	}
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
