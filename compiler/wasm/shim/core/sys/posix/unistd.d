module core.sys.posix.unistd;
extern (C) nothrow @nogc:

alias off_t = long;
alias ssize_t = ptrdiff_t;
alias uid_t = uint;
alias gid_t = uint;

// wasi-libc has no uid/gid concept; these are only referenced by the
// (never-executed in wasm) library writer in dmd.lib.*, so they are inert.
extern (D) uid_t getuid() { return 0; }
extern (D) gid_t getgid() { return 0; }

enum STDIN_FILENO  = 0;
enum STDOUT_FILENO = 1;
enum STDERR_FILENO = 2;

int close(int fd);
ssize_t read(int fd, void* buf, size_t n);
ssize_t write(int fd, const(void)* buf, size_t n);
int ftruncate(int fd, off_t length);
int unlink(const(char)* path);
off_t lseek(int fd, off_t offset, int whence);
char* getcwd(char* buf, size_t size);
int chdir(const(char)* path);
int isatty(int fd);
int access(const(char)* path, int mode);
int rmdir(const(char)* path);
long pathconf(const(char)* path, int name);

enum _PC_PATH_MAX = 4;
