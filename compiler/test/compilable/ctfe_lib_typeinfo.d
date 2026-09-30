// REQUIRED_ARGS: -lib
bool f()
{
    auto ti = typeid(const(Object));
    return ti !is null;
}

static assert(f());
