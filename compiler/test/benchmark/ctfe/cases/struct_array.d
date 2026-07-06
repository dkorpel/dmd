// Struct field mutation over a dynamic array.
// Stresses aggregate representation (StructLiteralExp / ArrayLiteralExp today).
module struct_array;

struct Vec
{
    double x, y, z;
}

double simulate(int n, int steps)
{
    Vec[] ps;
    ps.length = n;
    foreach (i; 0 .. n)
        ps[i] = Vec(i, i * 2.0, i * 3.0);

    double energy = 0;
    foreach (step; 0 .. steps)
    {
        foreach (ref p; ps)
        {
            p.x += p.y * 0.5;
            p.y += p.z * 0.25;
            p.z *= 0.999;
            energy += p.x;
        }
    }
    return energy;
}

enum result = simulate(1000, 50);
static assert(result > 0);
