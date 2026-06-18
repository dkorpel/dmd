module extracttypes_input;

enum Color : ubyte { red, green = 5, blue }

// A struct used only as a UDA - it must be pulled into the isolated module too
struct Tag { string name; }

struct Point { double x, y; }

class Base
{
    int id;
    void method() {}   // dropped
}

@Tag("shape")
class Shape : Base
{
    Color color;
    @Tag("pts") Point[] points;
    string name;
    Point* origin;
    int[string] tags;
    static int counter;   // not an instance field
    void draw() {}        // dropped
}
