#ifndef NIPCFRAME_H
#define NIPCFRAME_H
#include <sys/types.h>
#include <stddef.h>

#define NIPC_SOCKET_PATH "/var/run/navigatiod.sock"
#define NIPC_MAX_FRAME   (256 * 1024)

int nipc_send_frame(int fd, const void *data, size_t len);
int nipc_recv_frame(int fd, char *out, size_t cap, size_t *outLen);

#endif
