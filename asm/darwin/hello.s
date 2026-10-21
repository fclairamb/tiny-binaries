// hello for macOS arm64: write(1, "Hello, World!\n", 14), then exit(0).
// Raw BSD system calls: number in x16, arguments in x0-x2, `svc #0x80`.
// dyld calls _main (LC_MAIN) like a C main.

        .text
        .globl  _main
        .p2align 2
_main:
        mov     x0, #1                  // stdout
        adrp    x1, msg@PAGE
        add     x1, x1, msg@PAGEOFF
        mov     x2, #14                 // length
        mov     x16, #4                 // SYS_write
        svc     #0x80

        mov     x0, #0                  // status 0
        mov     x16, #1                 // SYS_exit
        svc     #0x80

        .section __TEXT,__const
msg:    .ascii  "Hello, World!\n"
