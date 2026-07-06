// Quicksort of a pseudorandom array: recursion, slicing, and swaps.
// Stresses call frames, array indexing, and element assignment.
module sort_array;

uint[] makeArray(int n)
{
    auto a = new uint[](n);
    uint state = 0x9E3779B9;
    foreach (i; 0 .. n)
    {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        a[i] = state;
    }
    return a;
}

void quicksort(uint[] a)
{
    if (a.length < 2)
        return;
    immutable pivot = a[a.length / 2];
    size_t lo = 0;
    size_t hi = a.length - 1;
    while (lo <= hi)
    {
        while (a[lo] < pivot)
            lo++;
        while (a[hi] > pivot)
        {
            if (hi == 0)
                break;
            hi--;
        }
        if (lo > hi)
            break;
        immutable tmp = a[lo];
        a[lo] = a[hi];
        a[hi] = tmp;
        lo++;
        if (hi == 0)
            break;
        hi--;
    }
    quicksort(a[0 .. hi + 1]);
    quicksort(a[lo .. $]);
}

ulong checksum(int n)
{
    auto a = makeArray(n);
    quicksort(a);
    ulong sum = 0;
    foreach (i, v; a)
        sum += v * (i + 1);
    return sum;
}

enum result = checksum(20_000);
static assert(result != 0);
