/**
 * Minimal core.time for wasm32-wasi (upstream static-asserts: unknown ClockType).
 * Frontend uses MonoTime only via timetrace.d; time-tracing is unused in the demo.
 */
module core.time;

struct MonoTime
{
  nothrow @nogc:
    long _ticks;
    long ticks() const @safe pure => _ticks;
    static long ticksPerSecond() @safe => 1_000_000;
    static MonoTime currTime() @trusted
    {
        import core.stdc.time : clock;
        return MonoTime(cast(long) clock());
    }
    MonoTime opBinary(string op : "-")(MonoTime rhs) const @safe pure => MonoTime(_ticks - rhs._ticks);
    long opCmp(MonoTime rhs) const @safe pure => _ticks - rhs._ticks;
}

struct Duration
{
  nothrow @nogc:
    long _hnsecs;
    long total(string units)() const @safe pure => _hnsecs;
}
