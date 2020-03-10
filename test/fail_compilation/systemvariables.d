

@system int x;
@system int* y;

void main() @safe {
	@safe int z;
	z++;

	U u;
	cast(void) u.x;
	u.x = 3;
	cast(void) u.c;
	u.c = null;

	foreach(attr; __traits(getFunctionAttributes, z)) {
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
