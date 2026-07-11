version (D_ModuleInfo)
{ }
else version (WebAssembly)
{ }
else
{
    static assert(0);
}

version (D_Exceptions)
{ }
else
{
    static assert(0);
}

version (D_TypeInfo)
{ }
else
{
    static assert(0);
}
