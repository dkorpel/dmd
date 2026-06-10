module core.sys.posix.stdlib;
extern (C) nothrow @nogc:

char* realpath(const(char)* path, char* resolved_path) => null;  // stub: not in base wasi-libc
char* getenv(const(char)* name);
int setenv(const(char)* name, const(char)* value, int overwrite);
int mkstemp(char* templ);
char* mkdtemp(char* templ);
