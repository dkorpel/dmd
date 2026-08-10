// PERMUTE_ARGS: -O
enum E : ubyte { s = 116, u = 117, c = 118, i = 119 }

bool inRange(T)(T v) { return v == 116 || v == 117 || v == 118 || v == 119; }

void main()
{
    assert(!inRange!ubyte(85));
    assert(!inRange!char(85));
    assert(!inRange!ushort(85));
    assert(!inRange!int(85));
    assert(!inRange!uint(85));
    assert(!inRange!E(cast(E) 85));
    foreach (int v; 116 .. 120)
        assert(inRange!int(v) && inRange!ubyte(cast(ubyte) v) && inRange!E(cast(E) v));
}
