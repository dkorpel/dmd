uint f(double d) { return cast(uint) d; }

static assert(f(-128.0) == 0xFFFF_FF80);
static assert(f(4e9) == 4_000_000_000u);
