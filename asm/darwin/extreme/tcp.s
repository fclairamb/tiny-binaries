// tcp, extreme: tcp <ipv4> <port>. Same logic as ../tcp.s, in a hand-written Mach-O.
// Raw system calls (x16 = number, svc #0x80, carry set on error with the errno in
// x0). Every failure exits with that errno: ECONNREFUSED 61, ECONNRESET 54.
// A successful call also sets x1, so x1 is reloaded before every call.

        .include "macho.inc"

        .set    BUFSZ, 0x4000

Lentry: cmp     x0, #3                  // argc (dyld passes it in x0, argv in x1)
        b.lo    Lusage
        ldp     x9, x10, [x1, #8]       // argv[1] dotted quad, argv[2] port
        bl      Lparse                  // w12 = a<<24 | b<<16 | c<<8 | d
        rev     w11, w12                // sin_addr, a.b.c.d in memory order
        mov     x9, x10
        bl      Lparse                  // w12 = port
        rev16   w12, w12                // big-endian
        mov     x13, #0x0210            // sin_len 16, sin_family AF_INET
        bfi     x13, x12, #16, #16      // sin_port
        bfi     x13, x11, #32, #32      // sin_addr
        stp     x13, xzr, [sp, #-16]!   // sockaddr_in on the stack, sin_zero 0

        mov     x0, #2                  // socket(AF_INET, SOCK_STREAM, 0)
        mov     x1, #1
        mov     x2, #0
        mov     x16, #97
        svc     #0x80
        b.cs    Lexit
        mov     x19, x0                 // fd
        mov     x1, sp                  // connect(fd, &sockaddr, 16)
        mov     x2, #16
        mov     x16, #98
        svc     #0x80
        b.cs    Lexit
        mov     x0, x19                 // write(fd, "hello\n", 6)
        adr     x1, Lreq
        mov     x2, #6
        mov     x16, #4
        svc     #0x80
        b.cs    Lexit

        sub     sp, sp, #BUFSZ
Lcopy:  mov     x0, x19                 // read(fd, buf, BUFSZ)
        mov     x1, sp
        mov     x2, #BUFSZ
        mov     x16, #3
        svc     #0x80
        b.cs    Lexit                   // reset mid-reply: ECONNRESET
        cbz     x0, Lexit               // end of stream: status 0
        mov     x2, x0                  // write(1, buf, n): a blocking write
        mov     x0, #1                  // to a pipe or file writes all n bytes
        mov     x1, sp
        mov     x16, #4
        svc     #0x80
        b.cs    Lexit
        b       Lcopy

Lusage: mov     x0, #1
Lexit:  mov     x16, #1                 // exit(x0)
        svc     #0x80

// Lparse: decimal numbers separated by any non-digit, up to the NUL at x9.
// Returns w12 = the numbers packed one per byte, the last one in the low byte.
Lparse: mov     w12, #0
        mov     w13, #0
        mov     w15, #10
1:      ldrb    w14, [x9], #1
        sub     w16, w14, #'0'
        cmp     w16, #9
        b.hi    2f
        madd    w13, w13, w15, w16      // digit
        b       1b
2:      orr     w12, w13, w12, lsl #8   // separator or NUL: push the number
        mov     w13, #0
        cbnz    w14, 1b
        ret

Lreq:   .ascii  "hello\n"
