#include "graft_wayland_io.h"

#include <errno.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

int graft_unix_listen(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(address.sun_path)) {
        close(fd);
        errno = ENAMETOOLONG;
        return -1;
    }
    strncpy(address.sun_path, path, sizeof(address.sun_path) - 1);
    unlink(path);

    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        close(fd);
        return -1;
    }
    if (listen(fd, 4) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

int graft_unix_connect(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(address.sun_path)) {
        close(fd);
        errno = ENAMETOOLONG;
        return -1;
    }
    strncpy(address.sun_path, path, sizeof(address.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

int graft_send_message(int socket_fd,
                       const void *header,
                       size_t header_len,
                       const void *payload,
                       size_t payload_len,
                       int pass_fd) {
    struct iovec iov[2];
    iov[0].iov_base = (void *)header;
    iov[0].iov_len = header_len;
    iov[1].iov_base = (void *)payload;
    iov[1].iov_len = payload_len;

    struct msghdr message;
    memset(&message, 0, sizeof(message));
    message.msg_iov = iov;
    message.msg_iovlen = payload_len > 0 ? 2 : 1;

    char control[CMSG_SPACE(sizeof(int))];
    memset(control, 0, sizeof(control));
    if (pass_fd >= 0) {
        message.msg_control = control;
        message.msg_controllen = sizeof(control);
        struct cmsghdr *cmsg = CMSG_FIRSTHDR(&message);
        cmsg->cmsg_level = SOL_SOCKET;
        cmsg->cmsg_type = SCM_RIGHTS;
        cmsg->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(cmsg), &pass_fd, sizeof(int));
    }

    size_t expected = header_len + payload_len;
    ssize_t written = sendmsg(socket_fd, &message, 0);
    if (written < 0) {
        return -1;
    }
    return (size_t)written == expected ? 0 : -1;
}

long graft_recv_message(int socket_fd, void *buffer, size_t length, int *received_fd) {
    if (received_fd) {
        *received_fd = -1;
    }

    struct iovec iov;
    iov.iov_base = buffer;
    iov.iov_len = length;

    char control[CMSG_SPACE(sizeof(int))];
    struct msghdr message;
    memset(&message, 0, sizeof(message));
    memset(control, 0, sizeof(control));
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control;
    message.msg_controllen = sizeof(control);

    ssize_t received = recvmsg(socket_fd, &message, 0);
    if (received <= 0) {
        return received;
    }

    for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(&message);
         cmsg != NULL;
         cmsg = CMSG_NXTHDR(&message, cmsg)) {
        if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS) {
            int passed = -1;
            memcpy(&passed, CMSG_DATA(cmsg), sizeof(int));
            if (received_fd) {
                *received_fd = passed;
            } else {
                close(passed);
            }
            break;
        }
    }
    return (long)received;
}
