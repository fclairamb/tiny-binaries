// tcp for macOS arm64: tcp <ipv4> <port>
// Connects, sends "hello\n", copies the reply to stdout until the server closes.
//
// Raw BSD system calls: number in x16, arguments in x0-x2, `svc #0x80`. On error
// the kernel sets the carry flag and returns the errno (a small positive number)
// in x0, so every failure exits with that errno as the status: ECONNREFUSED is 61,
// ECONNRESET 54, all within 1..125. A successful call also overwrites x1, so
// nothing is kept in x0/x1 across a call.
//
// Registers kept across calls: x19 = socket fd, x20 = write pointer, x21 = bytes left.

        .set    BUFSZ, 16384

        .text
        .globl  _main
        .p2align 2
_main:
        sub     sp, sp, #BUFSZ          // read buffer
        sub     sp, sp, #16             // sockaddr_in at sp, so the buffer is at sp+16
        cmp     x0, #3                  // argc: program, address, port
        b.lt    usage
        ldp     x19, x20, [x1, #8]      // argv[1] address, argv[2] port

        mov     w0, #0x0210             // sin_len 16, sin_family AF_INET
        strh    w0, [sp]
        str     xzr, [sp, #8]           // sin_zero

        mov     x0, x20                 // port, stored big-endian
        bl      parse_uint
        rev16   w0, w0
        strh    w0, [sp, #2]

        mov     x0, x19                 // dotted quad, one byte per number
        mov     x21, #0
1:      bl      parse_uint
        add     x2, sp, #4              // sin_addr
        strb    w0, [x2, x21]
        add     x0, x1, #1              // skip the dot
        add     x21, x21, #1
        cmp     x21, #4
        b.lo    1b

        mov     x0, #2                  // socket(AF_INET, SOCK_STREAM, 0)
        mov     x1, #1
        mov     x2, #0
        mov     x16, #97
        svc     #0x80
        b.cs    exit
        mov     x19, x0

        mov     x0, x19                 // connect(fd, &addr, 16)
        mov     x1, sp
        mov     x2, #16
        mov     x16, #98
        svc     #0x80
        b.cs    exit

        mov     x0, x19                 // write(fd, "hello\n", 6)
        adrp    x1, request@PAGE
        add     x1, x1, request@PAGEOFF
        mov     x2, #6
        mov     x16, #4
        svc     #0x80
        b.cs    exit

copy:   mov     x0, x19                 // read(fd, buf, BUFSZ)
        add     x1, sp, #16
        mov     x2, #BUFSZ
        mov     x16, #3
        svc     #0x80
        b.cs    exit                    // a reset mid-reply ends here: ECONNRESET
        cbz     x0, exit                // end of stream: status 0
        add     x20, sp, #16
        mov     x21, x0
2:      mov     x0, #1                  // write(1, p, left) until all is out
        mov     x1, x20
        mov     x2, x21
        mov     x16, #4
        svc     #0x80
        b.cs    exit
        add     x20, x20, x0
        subs    x21, x21, x0
        b.ne    2b
        b       copy

usage:  mov     x0, #2                  // write(2, usage, len)
        adrp    x1, Lusage_msg@PAGE
        add     x1, x1, Lusage_msg@PAGEOFF
        mov     x2, #(Lusage_end - Lusage_msg)
        mov     x16, #4
        svc     #0x80
        mov     x0, #1
exit:   mov     x16, #1                 // exit(x0)
        svc     #0x80

// parse_uint: x0 = string. Returns w0 = value of its leading decimal digits,
// x1 = address of the first other character.
parse_uint:
        mov     w2, #0
        mov     w4, #10
1:      ldrb    w3, [x0]
        sub     w3, w3, #'0'
        cmp     w3, #9
        b.hi    2f
        madd    w2, w2, w4, w3
        add     x0, x0, #1
        b       1b
2:      mov     x1, x0
        mov     w0, w2
        ret

        .section __TEXT,__const
request:
        .ascii  "hello\n"
Lusage_msg:
        .ascii  "usage: tcp <ipv4> <port>\n"
Lusage_end:
