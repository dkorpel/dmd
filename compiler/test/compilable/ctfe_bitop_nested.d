/*
EXTRA_FILES: imports/ctfe_table.d
*/
import core.bitop;
import imports.ctfe_table;

auto fold(uint i)
{
    alias t = table;
    static struct R
    {
        uint idx;
        uint front() const { return t(idx).x; }
    }
    return R(i).front;
}
static assert(fold(1) == 0x02020202);

bool bits()
{
    size_t[3] a;
    assert(!bts(a.ptr, 70));
    assert(bts(a.ptr, 70));
    assert(bt(a.ptr, 70));
    enum W = 8 * size_t.sizeof;
    assert(a[70 / W] == size_t(1) << (70 % W));
    assert(btc(a.ptr, 3) == 0);
    assert(btr(a.ptr, 3) == 1);
    assert(btr(a.ptr, 70) == 1);
    return a[0] == 0 && a[1] == 0 && a[2] == 0;
}
static assert(bits());

size_t g(int[] s, int[] d) { return s.length * 10 + d.length; }

size_t grow(ref int[] array, size_t pos)
{
    immutable oldLen = array.length;
    array.length += 1;
    return (() => g(array[pos .. oldLen], array[pos + 1 .. $]))();
}
static assert(() { int[] a = [1, 2, 3, 4, 5]; return grow(a, 2); }() == 33);
