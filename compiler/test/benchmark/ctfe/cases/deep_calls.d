// Deep recursion with small frames.
// Stresses CtfeStack frame push/pop and per-call value setup.
module deep_calls;

int ackermannish(int m, int n, ref int budget)
{
    if (--budget <= 0)
        return n;
    if (m == 0)
        return n + 1;
    if (n == 0)
        return ackermannish(m - 1, 1, budget);
    return ackermannish(m - 1, ackermannish(m, n - 1, budget), budget);
}

int run()
{
    int total = 0;
    foreach (i; 0 .. 40)
    {
        int budget = 20_000;
        total += ackermannish(3, 3, budget);
    }
    return total;
}

enum result = run();
static assert(result != 0);
