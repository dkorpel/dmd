// https://issues.dlang.org/show_bug.cgi?id=16528

void fun1()()
{
    fun2();
}

void fun2()()
{
    fun1();
}

void main() @safe pure nothrow @nogc
{
    fun1();
}
