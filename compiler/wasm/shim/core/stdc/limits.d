/**
 * core.stdc.limits for wasm32-wasi (upstream static-asserts "unsupported OS").
 */
module core.stdc.limits;

extern (C):

enum CHAR_BIT  = 8;
enum SCHAR_MIN = byte.min;
enum SCHAR_MAX = byte.max;
enum UCHAR_MAX = ubyte.max;
enum CHAR_MIN  = char.min;
enum CHAR_MAX  = char.max;
enum MB_LEN_MAX = 16;
enum SHRT_MIN  = short.min;
enum SHRT_MAX  = short.max;
enum USHRT_MAX = ushort.max;
enum INT_MIN   = int.min;
enum INT_MAX   = int.max;
enum UINT_MAX  = uint.max;
enum LONG_MIN  = int.min;   // C `long` is 32-bit on wasm32
enum LONG_MAX  = int.max;
enum ULONG_MAX = uint.max;
enum LLONG_MIN = long.min;
enum LLONG_MAX = long.max;
enum ULLONG_MAX = ulong.max;
enum PATH_MAX  = 4096;
