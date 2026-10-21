// hello, extreme: the file is this source assembled byte for byte (header included),
// then signed by sign.py. Raw system calls, no libSystem.

        .include "macho.inc"

Lentry: mov     x0, #1                  // stdout
        adr     x1, Lmsg
        mov     x2, #14
        mov     x16, #4                 // SYS_write
        svc     #0x80
        mov     x0, #0
        mov     x16, #1                 // SYS_exit
        svc     #0x80
Lmsg:   .ascii  "Hello, World!\n"
