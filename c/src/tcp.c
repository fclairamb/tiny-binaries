#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <ipv4> <port>\n", argv[0]);
        return 1;
    }
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(atoi(argv[2]));
    if (inet_pton(AF_INET, argv[1], &addr.sin_addr) != 1) {
        fprintf(stderr, "bad address: %s\n", argv[1]);
        return 1;
    }
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0 || connect(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
        perror("connect");
        return 1;
    }
    if (write(fd, "hello\n", 6) != 6) {
        perror("write");
        return 1;
    }
    char buf[4096];
    ssize_t n;
    while ((n = read(fd, buf, sizeof buf)) > 0)
        fwrite(buf, 1, n, stdout);
    if (n < 0) {
        perror("read");
        return 1;
    }
    close(fd);
    return 0;
}
