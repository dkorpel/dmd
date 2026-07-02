// Switch structuring: case-body breaks branch to the block after the switch,
// which lies past every case start — it needs its own wrapper block or the
// breaks are silently dropped and cases fall through.
//
// Run via: OS=wasm ./run.d runnable/wasm_switch.d
// DISABLED: linux osx freebsd windows dragonflybsd openbsd netbsd solaris

// dense br_table switch: every case break must skip the remaining cases
extern (C) int classify(int c)
{
    int base = 0;
    switch (c)
    {
    case 'x':
        base = 16;
        break;
    case 'X':
        base = 16;
        break;
    case 'b':
    case 'B':
        base = 2;
        break;
    case 'd':
    case 'D':
        base = 10;
        break;
    case 's':
        base = 0;
        break;
    default:
        base = -1;
    }
    return base;
}

// switch inside a loop with `if (cond) break; continue;` case bodies:
// both branch targets are non-adjacent, so the iftrue must emit real
// branches (not evaluate-and-drop)
extern (C) int countMatching(const(char)* s, int len, char target)
{
    int n;
    foreach (i; 0 .. len)
    {
        switch (s[i])
        {
        case 'a':
            if (target == 'a')
                break;
            continue;
        case 'b':
            if (target == 'b')
                break;
            continue;
        default:
            continue;
        }
        n++;
    }
    return n;
}

// switch case containing if/else with the FALSE path inline, whose last
// block jumps past the true path to a local merge: needs a merge frame or
// the jump overshoots into the next case body
extern (C) int quantify(int tag, int nmin, int nmax, bool greedy)
{
    int first, second, pushed;
    final switch (tag)
    {
    case 0:
        pushed = 1;
        break;
    case 1:
        if (nmax >= 0 && nmax < nmin)
        {
            pushed = 2;
        }
        else if (nmax == int.max)
        {
            pushed = 3;
            if (nmin == 0)
            {
                pushed += 4;
                first = 10;
            }
            else
            {
                first = 20;
            }
            if (!greedy)
            {
                const t = first;
                first = second;
                second = t;
            }
        }
        break;
    case 2:
        pushed = 6;
        break;
    case 3:
        pushed = 7;
        break;
    }
    return pushed * 10000 + first * 100 + second;
}

extern (C) int main()
{
    if (classify('x') != 16)
        return 1;
    if (classify('d') != 10)
        return 2;
    if (classify('s') != 0)
        return 3;
    if (classify('q') != -1)
        return 4;
    if (countMatching("abcab", 5, 'a') != 2)
        return 5;
    if (countMatching("abcab", 5, 'b') != 2)
        return 6;
    if (countMatching("abcab", 5, 'c') != 0)
        return 7;
    // non-greedy infinite quantifier: pushed=7, then swap → first=0, second=10
    if (quantify(1, 0, int.max, false) != 7 * 10000 + 0 * 100 + 10)
        return 8;
    // greedy: no swap
    if (quantify(1, 0, int.max, true) != 7 * 10000 + 10 * 100 + 0)
        return 9;
    // nmin>0: else arm
    if (quantify(1, 1, int.max, true) != 3 * 10000 + 20 * 100 + 0)
        return 10;
    if (quantify(2, 0, 0, true) != 6 * 10000)
        return 11;
    return 0;
}
