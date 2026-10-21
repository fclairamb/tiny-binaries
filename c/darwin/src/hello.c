/* hello, extreme: no libc, raw write(2) syscall. Entry is called by dyld via
 * LC_MAIN as main(argc, argv, ...); returning hands the status to libdyld. */
#include "syscall.h"

int _start(void) {
    sys(SYS_write, 1, (long)"Hello, World!\n", 14);
    return 0;
}
