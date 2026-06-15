module extracttypes_input;

enum Color : ubyte { red, green = 5, blue }

struct Point { double x, y; }

class Base
{
    int id;
    void method() {}   // dropped
}

class Shape : Base
{
    Color color;
    Point[] points;
    string name;
    Point* origin;
    int[string] tags;
    static int counter;   // not an instance field
    void draw() {}        // dropped
}
