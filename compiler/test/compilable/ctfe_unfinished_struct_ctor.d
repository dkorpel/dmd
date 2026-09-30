extern(C++, "ns")
struct Date
{
extern(D):
    this(int y, int m, int d)
    {
        _dayNumber = y * 365 + m * 31 + d;
    }
    private enum uint start = Date(1900, 1, 1)._dayNumber;
    private enum uint end = Date(1900, 1, 3)._dayNumber;
    static immutable dict = ()
    {
        uint[Date.end - Date.start] r;
        return r;
    }();
    uint get() const { return dict[0]; }
    int _dayNumber;
}
static assert(Date.dict.length == 2);
