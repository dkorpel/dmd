// Scalar arithmetic: a tight loop producing many integer intermediates.
// Stresses per-operation value allocation (IntegerExp today).
module int_loop;

long mix(long x, int iterations)
{
    long acc = 0;
    foreach (i; 0 .. iterations)
    {
        x = x * 6364136223846793005L + 1442695040888963407L;
        acc += (x >>> 33) ^ x;
    }
    return acc;
}

enum result = mix(123, 300_000);
static assert(result != 0);
