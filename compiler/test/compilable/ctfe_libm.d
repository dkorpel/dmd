import core.math : cos, ldexp, sin;

float f(float a, float b) { return a % b; }
double g(double a, double b) { return a % b; }

static assert(f(5.5f, 2) == 1.5f);
static assert(f(-5.5f, 2) == -1.5f);
static assert(g(7.25, 2) == 1.25);
static assert(g(0.5, 1) == 0.5);
static assert(g(-0.0, 1) is -0.0);

float sf(float x) { return sin(x); }
float cf(float x) { return cos(x); }
double sd(double x) { return sin(x); }
double cd(double x) { return cos(x); }
float lf(float x) { return ldexp(x, 3); }
double ld(double x) { return ldexp(x, -2); }

static assert(sf(0.5f) > 0.4794 && sf(0.5f) < 0.4795);
static assert(cf(0.5f) > 0.8775 && cf(0.5f) < 0.8776);
static assert(sd(0.7) > 0.6442 && sd(0.7) < 0.6443);
static assert(cd(0.7) > 0.7648 && cd(0.7) < 0.7649);
static assert(lf(0.75f) == 6);
static assert(ld(3) == 0.75);
