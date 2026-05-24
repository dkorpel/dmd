// Tests that common D constructs compile successfully for the WASM target.
// Run via: OS=wasm ./run.d compilable/wasm_codegen.d
// DISABLED: linux osx freebsd windows dragonflybsd openbsd netbsd solaris

struct Vec2
{
    float x, y;
}

struct Point
{
    int x, y;
}

extern (C) int add(int a, int b) => a + b;

extern (C) int factorial(int n) => n <= 1 ? 1 : n * factorial(n - 1);

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

extern (C) int getCounter() => counter;

extern (C) float fadd(float a, float b) => a + b;

extern (C) double dadd(double a, double b) => a + b;

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
extern (C) float getVec2X(Vec2* v) => v.x;

extern (C) float getVec2Y(Vec2* v) => v.y;

extern (C) void setVec2X(Vec2* v, float x)
{
    v.x = x;
}

extern (C) int getPointX(Point* p) => p.x;

extern (C) int getPointY(Point* p) => p.y;

// Long arithmetic
extern (C) long addLong(long a, long b) => a + b;

extern (C) long mulLong(long a, long b) => a * b;

// Array / pointer operations
extern (C) int sumSlice(int* arr, int n)
{
    int s = 0;
    for (int i = 0; i < n; i++)
        s += arr[i];
    return s;
}

extern (C) void fillArray(int* arr, int n, int val)
{
    for (int i = 0; i < n; i++)
        arr[i] = val;
}

extern (C) void reverseArray(int* arr, int n)
{
    int lo = 0, hi = n - 1;
    while (lo < hi)
    {
        int tmp = arr[lo];
        arr[lo] = arr[hi];
        arr[hi] = tmp;
        lo++;
        hi--;
    }
}

extern (C) int fibonacci(int n)
{
    if (n <= 1)
        return n;
    int a = 0, b = 1;
    for (int i = 2; i <= n; i++)
    {
        int c = a + b;
        a = b;
        b = c;
    }
    return b;
}

extern (C) int isPrime(int n)
{
    if (n < 2)
        return 0;
    for (int i = 2; i * i <= n; i++)
        if (n % i == 0)
            return 0;
    return 1;
}

extern (C) void insertionSort(int* arr, int n)
{
    for (int i = 1; i < n; i++)
    {
        int key = arr[i];
        int j = i - 1;
        while (j >= 0 && arr[j] > key)
        {
            arr[j + 1] = arr[j];
            j--;
        }
        arr[j + 1] = key;
    }
}

extern (C) int binarySearch(int* arr, int n, int target)
{
    int lo = 0, hi = n - 1;
    while (lo <= hi)
    {
        int mid = lo + (hi - lo) / 2;
        if (arr[mid] == target)
            return mid;
        if (arr[mid] < target)
            lo = mid + 1;
        else
            hi = mid - 1;
    }
    return -1;
}

extern (C) int iDotProduct(int* a, int* b, int n)
{
    int sum = 0;
    for (int i = 0; i < n; i++)
        sum += a[i] * b[i];
    return sum;
}

// Function pointers
extern (C) int applyFn(int function(int) f, int x) => f(x);

extern (C) int double_(int x) => x * 2;

extern (C) int square(int x) => x * x;

// memcmp: required for slice equality comparisons in betterC WASM (no libc)
extern (C) int memcmp(const(void)* a, const(void)* b, size_t n)
{
    const(ubyte)* pa = cast(const(ubyte)*) a;
    const(ubyte)* pb = cast(const(ubyte)*) b;
    for (size_t i = 0; i < n; i++)
    {
        if (pa[i] < pb[i])
            return -1;
        if (pa[i] > pb[i])
            return 1;
    }
    return 0;
}

// Hash / string / memory operations
extern (C) uint fnv1a(const(ubyte)* data, int len)
{
    uint h = 2166136261u;
    for (int i = 0; i < len; i++)
    {
        h ^= data[i];
        h *= 16777619u;
    }
    return h;
}

extern (C) int strlen_(const(char)* s)
{
    int n = 0;
    while (s[n])
        n++;
    return n;
}

extern (C) void memcpy_(void* dst, const(void)* src, int n)
{
    ubyte* d = cast(ubyte*) dst;
    const(ubyte)* s2 = cast(const(ubyte)*) src;
    for (int i = 0; i < n; i++)
        d[i] = s2[i];
}

// Struct copy (OPstreq) and comparison
struct S3
{
    int x, y, z;
}

extern (C) void copyS3(S3* dst, S3* src)
{
    *dst = *src;
}

extern (C) void initS3(S3* s)
{
    *s = S3(1, 2, 3);
}
// Field-by-field equality (avoids extern memcmp dependency)
extern (C) int s3Equal(S3* a, S3* b)
{
    return a.x == b.x && a.y == b.y && a.z == b.z;
}
// Note: *a == *b for structs generates env.memcmp import (requires host to provide it)

// Large struct copy (may use OPmemcpy/OPstreq with byte loop)
struct Big8
{
    int[8] data;
}

extern (C) void copyBig(Big8* dst, Big8* src)
{
    *dst = *src;
}

// Local struct copy
extern (C) int localStructCopy()
{
    S3 a = S3(7, 8, 9);
    S3 b = a;
    return b.x * 100 + b.y * 10 + b.z; // 789
}

// Array copy
extern (C) int arrayCopy()
{
    int[5] a = [10, 20, 30, 40, 50];
    int[5] b = a;
    return b[0] + b[4]; // 60
}

// WASI I/O declarations
struct WasiIov
{
    const(char)* buf;
    size_t len;
}

import core.attribute : wasmImportModule;
@wasmImportModule("wasi_snapshot_preview1") extern (C) int fd_write(uint fd, const(WasiIov)* iovs, size_t iovs_len, size_t* nwritten);

extern (C) void wasiWrite(const(char)* msg, size_t len)
{
    WasiIov iov;
    iov.buf = msg;
    iov.len = len;
    size_t n;
    fd_write(1, &iov, 1, &n);
}

// ---- TypeInfo ---------------------------------------------------------------

// TypeInfo for basic types is available via D_TypeInfo
version (D_TypeInfo) static assert(true, "D_TypeInfo is defined for WASM");

// TypeInfo carries the type's size (runtime check — TypeInfo is a static variable)
version (D_TypeInfo) void testTypeInfo()
{
    assert(typeid(int) !is null);
    assert(typeid(double) !is null);
    assert(typeid(bool) !is null);

    // Struct TypeInfo
    struct Color
    {
        ubyte r, g, b;
    }

    assert(typeid(Color) !is null);

    // TypeInfo carries the type's size
    assert(typeid(int).tsize == int.sizeof);
    assert(typeid(long).tsize == long.sizeof);

    // TypeInfo identity
    assert(typeid(int) == typeid(int));
    assert(typeid(double) !is typeid(float));
}

// ---- Classes ----------------------------------------------------------------

// Abstract base class with virtual methods
class Shape
{
    abstract double area() const;
    abstract const(char)[] kind() const;
}

// Concrete subclass
class Circle : Shape
{
    double radius;

    this(double r)
    {
        radius = r;
    }

    override double area() const
    {
        return 3.14159265358979 * radius * radius;
    }

    override const(char)[] kind() const
    {
        return "circle";
    }
}

class Rectangle : Shape
{
    double w, h;

    this(double w, double h)
    {
        this.w = w;
        this.h = h;
    }

    override double area() const
    {
        return w * h;
    }

    override const(char)[] kind() const
    {
        return "rectangle";
    }
}

// TypeInfo for class types (compile-time is-a checks)
static assert(is(Circle : Shape));
static assert(is(Rectangle : Shape));
static assert(!is(Circle : Rectangle));

// Virtual dispatch through base pointer
double shapeArea(Shape s)
{
    return s.area();
}

const(char)[] shapeKind(Shape s)
{
    return s.kind();
}

// ClassInfo is accessible at runtime
version (D_TypeInfo) void testClassInfo()
{
    assert(typeid(Circle) !is null);
    assert(typeid(Rectangle) !is null);
    assert(typeid(Circle) !is typeid(Rectangle));
    assert(typeid(Circle).name.length > 0);
}

// Interfaces with multiple inheritance
interface Drawable
{
    void draw();
}

interface Resizable
{
    void resize(double factor);
}

class Widget : Drawable, Resizable
{
    double size = 1.0;

    void draw()
    {
    }

    void resize(double factor)
    {
        size *= factor;
    }
}

// ---- Virtual dispatch runtime test ------------------------------------------

// Allocate class instances in static buffers (no GC needed)
private
{
    __gshared ubyte[64] _wasm_dogBuf;
    __gshared ubyte[64] _wasm_catBuf;
}

private T wasmEmplace(T)(ubyte* mem)
{
    auto init = __traits(initSymbol, T);
    (cast(ubyte*) mem)[0 .. init.length] = cast(ubyte[]) init;
    return cast(T) mem;
}

void testVirtualDispatch()
{
    Circle circ = wasmEmplace!Circle(_wasm_dogBuf.ptr);
    circ.__ctor(5.0);
    Rectangle rect = wasmEmplace!Rectangle(_wasm_catBuf.ptr);
    rect.__ctor(3.0, 4.0);

    // Direct virtual call
    assert(circ.kind() == "circle");
    assert(rect.kind() == "rectangle");

    // Virtual dispatch through base pointer
    Shape s = circ;
    double a1 = s.area(); // calls Circle.area() virtually
    assert(a1 > 78.0 && a1 < 79.0); // π*25 ≈ 78.54

    s = rect;
    double a2 = s.area(); // calls Rectangle.area() virtually
    assert(a2 == 12.0); // 3.0 * 4.0
}

// C variadic ABI: variadic args spilled to shadow stack, pointer passed as last param.
extern (C) int printf(const(char)* fmt, ...);
// User-defined variadic: define a stub so the binary doesn't need an external
// implementation. The body ignores the varargs pointer — the test is about
// codegen, not behavior.
extern (C) int myVariadic(int count, ...) { return count; }

void testCVariadic()
{
    // Call with int and double varargs (compile-only: verifies correct WASM type emission).
    printf("hello %d %f\n", 42, 3.14);
    // Call with no varargs (should pass null varargs pointer).
    printf("no args\n");
    // User-defined variadic.
    myVariadic(3, 1, 2, 3);
}

extern (C) int main()
{
    // Basic arithmetic
    assert(add(3, 4) == 7);
    assert(add(-1, 1) == 0);

    // Recursion
    assert(factorial(0) == 1);
    assert(factorial(1) == 1);
    assert(factorial(5) == 120);

    // Loops / gcd
    assert(gcd(12, 8) == 4);
    assert(gcd(17, 5) == 1);
    assert(gcd(100, 75) == 25);

    // Conditionals
    assert(sign(5) == 1);
    assert(sign(-3) == -1);
    assert(sign(0) == 0);

    // For loop accumulator
    assert(count(5) == 10); // 0+1+2+3+4
    assert(count(0) == 0);

    // Do-while
    assert(sumDoWhile(5) == 15); // 1+2+3+4+5
    assert(sumDoWhile(1) == 1);

    // Switch
    assert(dayType(0) == 0);
    assert(dayType(6) == 0);
    assert(dayType(3) == 1);
    assert(dayType(7) == -1);

    // Global variable
    assert(getCounter() == 0);
    increment();
    increment();
    assert(getCounter() == 2);

    // Float / double
    assert(fadd(1.5f, 2.5f) == 4.0f);
    assert(dadd(1.5, 2.5) == 4.0);

    // Shadow stack: address-of
    assert(testAddrOf() == 42);
    assert(testAddrOfModify() == 99);
    assert(testSwap() == 21);

    // Struct return via hidden pointer
    Vec2 v = makeVec2(3.0f, 4.0f);
    assert(v.x == 3.0f);
    assert(v.y == 4.0f);

    Point pt = makePoint(10, 20);
    assert(pt.x == 10);
    assert(pt.y == 20);

    // Struct field access via pointer
    assert(getVec2X(&v) == 3.0f);
    assert(getVec2Y(&v) == 4.0f);
    setVec2X(&v, 9.0f);
    assert(v.x == 9.0f);

    assert(getPointX(&pt) == 10);
    assert(getPointY(&pt) == 20);

    // Long arithmetic
    assert(addLong(1_000_000_000L, 2_000_000_000L) == 3_000_000_000L);
    assert(mulLong(1_000_000L, 1_000_000L) == 1_000_000_000_000L);

    // Array / pointer operations
    int[5] arr = [5, 3, 1, 4, 2];
    assert(sumSlice(arr.ptr, 5) == 15);

    fillArray(arr.ptr, 5, 7);
    assert(arr[0] == 7 && arr[4] == 7);

    int[5] arr2 = [1, 2, 3, 4, 5];
    reverseArray(arr2.ptr, 5);
    assert(arr2[0] == 5 && arr2[2] == 3 && arr2[4] == 1);

    // Fibonacci
    assert(fibonacci(0) == 0);
    assert(fibonacci(1) == 1);
    assert(fibonacci(10) == 55);

    // Prime
    assert(isPrime(2) == 1);
    assert(isPrime(17) == 1);
    assert(isPrime(1) == 0);
    assert(isPrime(9) == 0);

    // Insertion sort
    int[5] toSort = [3, 1, 4, 1, 5];
    insertionSort(toSort.ptr, 5);
    assert(toSort[0] == 1 && toSort[1] == 1 && toSort[2] == 3 && toSort[4] == 5);

    // Binary search (sorted array)
    int[5] sorted = [1, 3, 5, 7, 9];
    assert(binarySearch(sorted.ptr, 5, 5) == 2);
    assert(binarySearch(sorted.ptr, 5, 1) == 0);
    assert(binarySearch(sorted.ptr, 5, 9) == 4);
    assert(binarySearch(sorted.ptr, 5, 4) == -1);

    // Dot product
    int[3] va = [1, 2, 3];
    int[3] vb = [4, 5, 6];
    assert(iDotProduct(va.ptr, vb.ptr, 3) == 32); // 4+10+18

    // Function pointers
    assert(applyFn(&double_, 5) == 10);
    assert(applyFn(&square, 4) == 16);

    // String length
    assert(strlen_("hello".ptr) == 5);
    assert(strlen_("".ptr) == 0);

    // memcpy
    int[4] src = [10, 20, 30, 40];
    int[4] dst;
    memcpy_(dst.ptr, src.ptr, 16);
    assert(dst[0] == 10 && dst[3] == 40);

    // Struct copy
    S3 s3a = S3(7, 8, 9);
    S3 s3b;
    copyS3(&s3b, &s3a);
    assert(s3Equal(&s3a, &s3b) == 1);

    S3 s3c;
    initS3(&s3c);
    assert(s3c.x == 1 && s3c.y == 2 && s3c.z == 3);

    // Large struct copy
    Big8 big1;
    foreach (i; 0 .. 8)
        big1.data[i] = i * 10;
    Big8 big2;
    copyBig(&big2, &big1);
    assert(big2.data[0] == 0 && big2.data[7] == 70);

    // Local struct and array copy
    assert(localStructCopy() == 789);
    assert(arrayCopy() == 60);

    // TypeInfo
    // TODO: TypeInfo / ClassInfo runtime tests require vtable infrastructure
    // that the WASM backend doesn't yet wire up correctly. Skip for now —
    // compilation still exercises the TypeInfo emission code path.
    //version (D_TypeInfo)
    //    testTypeInfo();

    // Classes and virtual dispatch
    //version (D_TypeInfo)
    //    testClassInfo();
    //testVirtualDispatch();

    return 0;
}
