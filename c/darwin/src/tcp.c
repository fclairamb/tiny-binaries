/* tcp, extreme: no libc, raw socket/connect/read/write syscalls. Logic (argv
 * parse, dotted-quad parse, copy loop, error checks) is all in C. */
#include "syscall.h"

/* parse an unsigned decimal; stops at first non-digit. */
static unsigned parse_uint(const char *s) {
    unsigned v = 0;
    while (*s >= '0' && *s <= '9') v = v * 10 + (unsigned)(*s++ - '0');
    return v;
}

/* parse a dotted quad into 4 network-order bytes; returns 0 on success. */
static int parse_ipv4(const char *s, unsigned char out[4]) {
    for (int i = 0; i < 4; i++) {
        if (i) { if (*s != '.') return -1; s++; }
        if (*s < '0' || *s > '9') return -1;
        unsigned v = 0;
        while (*s >= '0' && *s <= '9') v = v * 10 + (unsigned)(*s++ - '0');
        if (v > 255) return -1;
        out[i] = (unsigned char)v;
    }
    return *s ? -1 : 0;
}

int _start(int argc, char **argv) {
    if (argc < 3) return 1;

    unsigned char ip[4];
    if (parse_ipv4(argv[1], ip) != 0) return 1;
    unsigned port = parse_uint(argv[2]);
    if (port < 1 || port > 65535) return 1;

    /* struct sockaddr_in: len(1)=16, family(1)=AF_INET(2), port(2, net order),
     * addr(4), zero(8). Built by hand as 16 bytes, each written explicitly so
     * the compiler emits no memset/bzero call (which would need a GOT). */
    unsigned char addr[16];
    addr[0] = 16;
    addr[1] = 2;                       /* AF_INET */
    addr[2] = (unsigned char)(port >> 8);
    addr[3] = (unsigned char)(port & 0xff);
    addr[4] = ip[0]; addr[5] = ip[1]; addr[6] = ip[2]; addr[7] = ip[3];
    addr[8] = 0; addr[9] = 0; addr[10] = 0; addr[11] = 0;
    addr[12] = 0; addr[13] = 0; addr[14] = 0; addr[15] = 0;

    long fd = sys(SYS_socket, 2 /*AF_INET*/, 1 /*SOCK_STREAM*/, 0);
    if (fd < 0) return 1;
    if (sys(SYS_connect, fd, (long)addr, 16) < 0) return 1;
    if (sys(SYS_write, fd, (long)"hello\n", 6) != 6) return 1;

    char buf[1024];
    for (;;) {
        long n = sys(SYS_read, fd, (long)buf, sizeof buf);
        if (n < 0) return 1;
        if (n == 0) break;
        long off = 0;
        while (off < n) {
            long w = sys(SYS_write, 1, (long)(buf + off), n - off);
            if (w < 0) return 1;
            off += w;
        }
    }
    sys(SYS_close, fd, 0, 0);
    return 0;
}
