#ifndef GRAFT_WAYLAND_IO_H
#define GRAFT_WAYLAND_IO_H

#include <stddef.h>
#include <sys/types.h>

/// Creates, binds and listens on a Unix-domain stream socket.
int graft_unix_listen(const char *path);

/// Connects to a Unix-domain stream socket.
int graft_unix_connect(const char *path);

/// Sends one Wayland message. `pass_fd` may be -1. Returns 0 on success.
int graft_send_message(int socket_fd,
                       const void *header,
                       size_t header_len,
                       const void *payload,
                       size_t payload_len,
                       int pass_fd);

/// Receives bytes and at most one SCM_RIGHTS descriptor. Returns bytes read,
/// 0 on EOF, or -1 on error. `received_fd` is set to -1 when absent.
long graft_recv_message(int socket_fd, void *buffer, size_t length, int *received_fd);

#endif
