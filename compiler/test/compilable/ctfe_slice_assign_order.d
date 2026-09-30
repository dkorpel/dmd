size_t len(int[] a) { return a.length; }

class Node { int[] c; }

int run()
{
    auto n = new Node;
    n.c = [1, 2, 3];
    n.c = [cast(int) len(n.c)];
    return n.c[0];
}

static assert(run() == 3);
