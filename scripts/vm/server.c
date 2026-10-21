// Test server used inside the amd64 VM (scripts/vm-amd64.sh). Same protocol and payload as
// scripts/check.py: expects "hello\n", replies with PAYLOAD in 3 chunks, 50 ms apart.
//   server --payload        print the expected reply
//   server <ipv4> <port>    serve forever, one connection at a time
#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static char payload[16384];
static int plen;

static void send_all(int fd, const char *p, int n) {
    while (n > 0) {
        int w = write(fd, p, n);
        if (w <= 0) return;
        p += w;
        n -= w;
    }
}

int main(int argc, char **argv) {
    plen = sprintf(payload, "got: hello\n");
    for (int i = 0; i < 300; i++)
        plen += sprintf(payload + plen, "%05d abcdefghijklmnopqrstuvwxyz\n", i);
    if (argc == 2 && !strcmp(argv[1], "--payload")) {
        send_all(1, payload, plen);
        return 0;
    }
    if (argc != 3) return 2;
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_port = htons(atoi(argv[2]));
    inet_pton(AF_INET, argv[1], &a.sin_addr);
    int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (bind(s, (struct sockaddr *)&a, sizeof a) || listen(s, 16)) {
        perror("server");
        return 1;
    }
    for (;;) {
        int c = accept(s, 0, 0);
        if (c < 0) continue;
        struct timeval tv = {5, 0};
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        char req[64];
        int n = 0;
        while (n < (int)sizeof req) {
            int r = read(c, req + n, sizeof req - n);
            if (r <= 0) break;
            n += r;
            if (req[n - 1] == '\n') break;
        }
        if (n == 6 && !memcmp(req, "hello\n", 6)) {
            int cuts[] = {0, 11, 4000, plen};
            for (int i = 0; i < 3; i++) {
                send_all(c, payload + cuts[i], cuts[i + 1] - cuts[i]);
                usleep(50000);
            }
        } else {
            send_all(c, "bad request\n", 12);
        }
        close(c);
    }
}
