module test.dshell.extracttypes;

import dshell;
import std.algorithm : canFind;

// Tests the `-extractTypes=<name>` switch: extract a class/struct together with
// all of its transitive field-type dependencies into a single isolated module,
// keeping only fields (methods are dropped), then verify the result compiles.
int main()
{
    Vars.set("SRC", "$EXTRA_FILES/extracttypes_input.d");
    Vars.set("GEN", "$OUTPUT_BASE/Shape.d");

    // Generate the isolated module to stdout, redirected into $GEN
    auto genFile = File(Vars.GEN, "w");
    run("$DMD -m$MODEL -o- -c -extractTypes=Shape $SRC", genFile);
    genFile.close();

    const text = cast(string) read(Vars.GEN);

    // Methods must be stripped, fields and dependencies must be present
    assert(text.canFind("class Shape : Base"),  "missing root class with base");
    assert(text.canFind("class Base"),          "missing transitive base class");
    assert(text.canFind("struct Point"),        "missing struct dependency");
    assert(text.canFind("enum Color"),          "missing enum dependency");
    assert(text.canFind("Point[] points"),      "missing slice field");
    assert(!text.canFind("draw"),               "method should not be emitted");
    assert(!text.canFind("counter"),            "static field should not be emitted");

    // The generated module must compile on its own
    run("$DMD -m$MODEL -o- -c $GEN");

    return 0;
}
