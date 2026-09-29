/*
DISABLED: freebsd32 openbsd32 linux32 osx32 win32 hurd32
*/
void write(T...)(T t){}

struct Vec4
{
    __vector(float[4]) raw;

    this(const(float[4]) value...) inout pure @safe nothrow @nogc
    {
        __vector(float[4]) raw;
        raw[] = value[];
        this.raw = raw;
    }
}

void main()
{
    static immutable Vec4 v = Vec4(  1.0f, 2.0f, 3.0f, 4.0f );
    static assert(v.raw[2] == 3.0f);

    static foreach(d; 0 .. 4)
        write(v.raw[d], " ");
}
