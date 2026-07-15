/*
PERMUTE_ARGS:
REQUIRED_ARGS:
RUN_OUTPUT:
---
finished
---
*/

import core.stdc.stdio;

/* This isn't a very good test. If it 'fails' it just takes a very
 * long time. The performance improved by a factor of five between
 * 2.042 and 2.043.
 */
void main()
{
    uint[uint][] aa;
    aa.length = 10000;
    for(int i = 0; i < 10_000_000; i++)
    {
        size_t j = i % aa.length;
        uint k = i;
        uint l = i;
        aa[j][k] = l;
    }
    printf("finished\n");
    aa[] = null;
}

// This inserts 10M entries into 10k AAs, growing the heap to ~450 MB. It
// completes correctly under wasm (~4s) but exceeds the runner's 10s timeout
// when several wasmtime jobs contend for the CPU in parallel.
// DISABLED: wasm
