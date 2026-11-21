#include "NIPCFrame.h"
#include <sys/socket.h>
#include <errno.h>
#include <arpa/inet.h>

static int read_exact(int fd, void *buf, size_t len) {
    size_t got = 0;
    while (got < len) {
        ssize_t n = recv(fd, (char *)buf + got, len - got, 0);
        if (n == 0) return -1;
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        got += (size_t)n;
    }
    return 0;
}

static int write_exact(int fd, const void *buf, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, (const char *)buf + sent, len - sent, 0);
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        sent += (size_t)n;
    }
    return 0;
}

int nipc_send_frame(int fd, const void *data, size_t len) {
    if (len == 0 || len > NIPC_MAX_FRAME) return -1;
    uint32_t be = htonl((uint32_t)len);
    if (write_exact(fd, &be, 4) != 0) return -1;
    return write_exact(fd, data, len);
}

int nipc_recv_frame(int fd, char *out, size_t cap, size_t *outLen) {
    uint32_t be = 0;
    if (read_exact(fd, &be, 4) != 0) return -1;
    uint32_t len = ntohl(be);
    if (len == 0 || len > NIPC_MAX_FRAME || (size_t)len + 1 > cap) return -1;
    if (read_exact(fd, out, len) != 0) return -1;
    out[len] = '\0';
    if (outLen) *outLen = len;
    return 0;
}
