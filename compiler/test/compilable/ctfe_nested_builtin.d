import core.math : sqrt;

enum double r = sqrt(sqrt(16.0));
static assert(r == 2);
