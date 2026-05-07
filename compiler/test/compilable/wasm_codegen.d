// Tests that common D constructs compile successfully for the WASM target.
// REQUIRED_ARGS: -mwasm32 -os=wasm -o-

struct Vec2 { float x, y; }
struct Point { int x, y; }

extern (C) int add(int a, int b)
{
    return a + b;
}

extern (C) int factorial(int n)
{
    return n <= 1 ? 1 : n * factorial(n - 1);
}

extern (C) int gcd(int a, int b)
{
    while (b)
    {
        int t = b;
        b = a % b;
        a = t;
    }
    return a;
}

extern (C) int sign(int x)
{
    if (x > 0)
        return 1;
    else if (x < 0)
        return -1;
    return 0;
}

extern (C) int count(int n)
{
    int s = 0;
    for (int i = 0; i < n; i++)
        s += i;
    return s;
}

extern (C) int sumDoWhile(int n)
{
    int s = 0, i = 1;
    do
    {
        s += i;
        i++;
    }
    while (i <= n);
    return s;
}

extern (C) int dayType(int d)
{
    switch (d)
    {
    case 0:
    case 6:
        return 0;
    case 1:
    case 2:
    case 3:
    case 4:
    case 5:
        return 1;
    default:
        return -1;
    }
}

extern (C) __gshared int counter = 0;
extern (C) void increment()
{
    counter++;
}

extern (C) int getCounter()
{
    return counter;
}

extern (C) float fadd(float a, float b)
{
    return a + b;
}

extern (C) double dadd(double a, double b)
{
    return a + b;
}

// Shadow stack: address-of local variable
extern (C) int testAddrOf()
{
    int x = 42;
    int* p = &x;
    return *p;
}

extern (C) int testAddrOfModify()
{
    int x = 10;
    int* p = &x;
    *p = 99;
    return x;
}

extern (C) int testSwap()
{
    int a = 1, b = 2;
    int* pa = &a;
    int* pb = &b;
    int tmp = *pa;
    *pa = *pb;
    *pb = tmp;
    return a * 10 + b; // 21
}

// Struct return via hidden pointer
extern (C) Vec2 makeVec2(float x, float y)
{
    Vec2 v;
    v.x = x;
    v.y = y;
    return v;
}

extern (C) Point makePoint(int x, int y)
{
    Point p;
    p.x = x;
    p.y = y;
    return p;
}

// Struct field access via pointer
extern (C) float getVec2X(Vec2* v) { return v.x; }
extern (C) float getVec2Y(Vec2* v) { return v.y; }
extern (C) void setVec2X(Vec2* v, float x) { v.x = x; }
extern (C) int getPointX(Point* p) { return p.x; }
extern (C) int getPointY(Point* p) { return p.y; }

// Long arithmetic
extern (C) long addLong(long a, long b) { return a + b; }
extern (C) long mulLong(long a, long b) { return a * b; }
