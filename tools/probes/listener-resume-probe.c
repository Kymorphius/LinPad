// Observe one owned listener across suspend/resume without repairing it.
// Linux AArch64 is freestanding; Apple Silicon builds use POSIX wrappers for
// a native format/lifetime smoke test. See listener-resume-probe.md.
#ifdef __APPLE__
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#endif

typedef __UINT64_TYPE__ u64;
typedef __INT64_TYPE__ s64;
typedef __UINT32_TYPE__ u32;
typedef __UINT16_TYPE__ u16;
typedef __SIZE_TYPE__ usize;

struct linux_timespec { s64 sec, nsec; };
struct linux_pollfd { int fd; short events, revents; };
struct linux_sockaddr_in { u16 family, port; u32 address; unsigned char zero[8]; };
_Static_assert(sizeof(void *) == 8, "64-bit pointers required");
_Static_assert(sizeof(struct linux_timespec) == 16, "Linux timespec ABI");
_Static_assert(sizeof(struct linux_pollfd) == 8, "Linux pollfd ABI");
_Static_assert(sizeof(struct linux_sockaddr_in) == 16, "Linux sockaddr_in ABI");
_Static_assert(__builtin_offsetof(struct linux_sockaddr_in, address) == 4,
               "Linux sockaddr_in address offset");

// Nonzero initialized RW data avoids a BSS-only PT_LOAD in LinPad's loader.
static volatile u64 file_backed_guard = 1;

#ifndef __APPLE__
#if !defined(__aarch64__) || __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error This freestanding build requires little-endian Linux AArch64.
#endif
static s64 raw6(u64 number, u64 a, u64 b, u64 c, u64 d, u64 e, u64 f) {
    register u64 x0 __asm__("x0") = a;
    register u64 x1 __asm__("x1") = b;
    register u64 x2 __asm__("x2") = c;
    register u64 x3 __asm__("x3") = d;
    register u64 x4 __asm__("x4") = e;
    register u64 x5 __asm__("x5") = f;
    register u64 x8 __asm__("x8") = number;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x3),
                     "r"(x4), "r"(x5), "r"(x8) : "memory", "cc");
    return (s64) x0;
}
#else
static s64 result(s64 value) { return value < 0 ? -(s64) errno : value; }
#endif

static s64 close_fd(int fd) {
#ifdef __APPLE__
    return result(close(fd));
#else
    return raw6(57, fd, 0, 0, 0, 0, 0);
#endif
}

static s64 write_fd(int fd, const void *buffer, usize size) {
#ifdef __APPLE__
    return result(write(fd, buffer, size));
#else
    return raw6(64, fd, (u64) buffer, size, 0, 0, 0);
#endif
}

static s64 open_log(const char *path) {
#ifdef __APPLE__
    return result(open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600));
#else
    // openat(AT_FDCWD, path, O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC, 0600)
    return raw6(56, (u64) -100, (u64) path, 1 | 64 | 128 | 524288, 0600, 0, 0);
#endif
}

static s64 monotonic(struct linux_timespec *value) {
#ifdef __APPLE__
    struct timespec native;
    s64 r = result(clock_gettime(CLOCK_MONOTONIC, &native));
    if (!r) { value->sec = native.tv_sec; value->nsec = native.tv_nsec; }
    return r;
#else
    return raw6(113, 1, (u64) value, 0, 0, 0, 0);
#endif
}

static s64 sleep_remaining(struct linux_timespec *request,
                           struct linux_timespec *remaining) {
#ifdef __APPLE__
    struct timespec native = {request->sec, request->nsec}, rem = {0, 0};
    s64 r = result(nanosleep(&native, &rem));
    if (r == -EINTR) { remaining->sec = rem.tv_sec; remaining->nsec = rem.tv_nsec; }
    return r;
#else
    return raw6(101, (u64) request, (u64) remaining, 0, 0, 0, 0);
#endif
}

static s64 new_listener(void) {
#ifdef __APPLE__
    s64 fd = result(socket(AF_INET, SOCK_STREAM, 0));
    if (fd < 0) return fd;
    if (fcntl((int) fd, F_SETFL, O_NONBLOCK) < 0 ||
        fcntl((int) fd, F_SETFD, FD_CLOEXEC) < 0) {
        s64 error = -(s64) errno;
        close_fd((int) fd);
        return error;
    }
    return fd;
#else
    return raw6(198, 2, 1 | 0x800 | 0x80000, 0, 0, 0, 0);
#endif
}

static s64 bind_loopback(int fd) {
#ifdef __APPLE__
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address); address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    return result(bind(fd, (const struct sockaddr *) &address, sizeof(address)));
#else
    struct linux_sockaddr_in address = {2, 0, 0x0100007f, {0}};
    return raw6(200, fd, (u64) &address, sizeof(address), 0, 0, 0);
#endif
}

static s64 listen_fd(int fd) {
#ifdef __APPLE__
    return result(listen(fd, 1));
#else
    return raw6(201, fd, 1, 0, 0, 0, 0);
#endif
}

static s64 socket_name(int fd, unsigned *port) {
#ifdef __APPLE__
    struct sockaddr_in address = {0};
    socklen_t length = sizeof(address);
    s64 r = result(getsockname(fd, (struct sockaddr *) &address, &length));
    if (!r && length >= 4) *port = ntohs(address.sin_port);
#else
    struct linux_sockaddr_in address = {0, 0, 0, {0}};
    u32 length = sizeof(address);
    s64 r = raw6(204, fd, (u64) &address, (u64) &length, 0, 0, 0);
    if (!r && length >= 4)
        *port = ((unsigned) address.port >> 8) | ((unsigned) address.port << 8 & 0xffff);
#endif
    return r;
}

static s64 socket_option(int fd, int option, int *value) {
#ifdef __APPLE__
    socklen_t length = sizeof(*value);
    int native_option = option == 3 ? SO_TYPE : SO_ACCEPTCONN;
    return result(getsockopt(fd, SOL_SOCKET, native_option, value, &length));
#else
    u32 length = sizeof(*value);
    return raw6(209, fd, 1, option, (u64) value, (u64) &length, 0);
#endif
}

static s64 file_flags(int fd) {
#ifdef __APPLE__
    return result(fcntl(fd, F_GETFL));
#else
    return raw6(25, fd, 3, 0, 0, 0, 0);
#endif
}

static s64 poll_immediate(int fd, int *revents) {
#ifdef __APPLE__
    struct pollfd pfd = {fd, POLLIN, 0};
    s64 r = result(poll(&pfd, 1, 0));
#else
    struct linux_pollfd pfd = {fd, 1, 0};
    struct linux_timespec zero = {0, 0};
    s64 r = raw6(73, (u64) &pfd, 1, (u64) &zero, 0, 0, 0);
#endif
    *revents = (unsigned short) pfd.revents;
    return r;
}

static s64 accept_nonblocking(int fd) {
#ifdef __APPLE__
    return result(accept(fd, 0, 0));
#else
    return raw6(202, fd, 0, 0, 0, 0, 0);
#endif
}

static unsigned positive_errno(s64 r) { return r < 0 ? (unsigned) -r : 0; }
static u64 nanoseconds(struct linux_timespec value) {
    return (u64) value.sec * 1000000000ull + (u64) value.nsec;
}

struct json_line { char text[1024]; unsigned used; };
static void append(struct json_line *line, const char *text) {
    while (*text && line->used < sizeof(line->text)) line->text[line->used++] = *text++;
}
static void number(struct json_line *line, u64 value) {
    char digits[20]; unsigned n = 0;
    do { digits[n++] = (char) ('0' + value % 10); value /= 10; } while (value);
    while (n && line->used < sizeof(line->text)) line->text[line->used++] = digits[--n];
}
static void field(struct json_line *line, const char *key, u64 value) {
    append(line, ",\""); append(line, key); append(line, "\":"); number(line, value);
}
static void signed_field(struct json_line *line, const char *key, s64 value) {
    append(line, ",\""); append(line, key); append(line, "\":");
    if (value < 0) { append(line, "-"); number(line, (u64) -(value + 1) + 1); }
    else number(line, (u64) value);
}
static int emit(int fd, struct json_line *line) {
    append(line, "}\n");
    if (line->used >= sizeof(line->text)) return 0;
    unsigned offset = 0, interruptions = 0;
    while (offset < line->used) {
        s64 r = write_fd(fd, line->text + offset, line->used - offset);
        if (r == -4 && interruptions++ < 8) continue;
        if (r <= 0) return 0;
        offset += (unsigned) r;
    }
    return 1;
}
static void message(const char *text) {
    usize n = 0; while (text[n]) n++;
    // Diagnostics only, no terminal input or application data is read.
    write_fd(2, text, n);
}

static int probe_main(int argc, char **argv) {
    if (argc != 3 || !file_backed_guard) {
        message("usage: listener-resume-probe NEW_LOGPATH DURATION_SECONDS(15..300)\n");
        return 2;
    }
    unsigned duration = 0, digits = 0;
    const char *p = argv[2];
    while (*p >= '0' && *p <= '9' && digits++ < 4) duration = duration * 10 + (*p++ - '0');
    if (*p || !digits || duration < 15 || duration > 300) {
        message("duration must be an integer from 15 through 300\n"); return 2;
    }
    s64 log = open_log(argv[1]);
    if (log < 0) { message("cannot create new log (existing files are never replaced)\n"); return 3; }
    s64 listener = new_listener();
    s64 bind_result = listener < 0 ? listener : bind_loopback((int) listener);
    s64 listen_result = bind_result < 0 ? bind_result : listen_fd((int) listener);
    struct linux_timespec start = {0, 0};
    s64 clock_result = monotonic(&start);
    struct json_line line;
    line.used = 0;
    append(&line, "{\"event\":\"start\"");
    field(&line, "duration_seconds", duration);
    field(&line, "socket_errno", positive_errno(listener));
    field(&line, "bind_errno", positive_errno(bind_result));
    field(&line, "listen_errno", positive_errno(listen_result));
    field(&line, "clock_errno", positive_errno(clock_result));
#ifdef __APPLE__
    append(&line, ",\"platform\":\"darwin-native\",\"poll_api\":\"poll\"");
#else
    append(&line, ",\"platform\":\"linux-aarch64\",\"poll_api\":\"ppoll\"");
#endif
    int okay = emit((int) log, &line);
    int setup_ok = listener >= 0 && bind_result == 0 && listen_result == 0 && clock_result == 0;
    unsigned samples = 0, port = 0;
    u64 start_ns = nanoseconds(start), end_ns = start_ns + (u64) duration * 1000000000ull;
    // The iteration bound remains effective if the emulated clock is broken.
    for (unsigned i = 0; okay && setup_ok && i <= duration + 4; i++) {
        struct linux_timespec now = {0, 0};
        clock_result = monotonic(&now);
        if (clock_result < 0) { okay = 0; break; }
        u64 now_ns = nanoseconds(now);
        if (now_ns >= end_ns || now_ns < start_ns) break;
        int revents = 0, type = -1, accepting = -1;
        s64 polled = poll_immediate((int) listener, &revents);
        // A nonblocking accept is intentional even when poll reports no input.
        s64 accepted = accept_nonblocking((int) listener);
        s64 accepted_close = accepted >= 0 ? close_fd((int) accepted) : 0;
        s64 named = socket_name((int) listener, &port);
        s64 typed = socket_option((int) listener, 3, &type);
        s64 accept_option = socket_option((int) listener, 30, &accepting);
        s64 flags = file_flags((int) listener);
        line.used = 0; append(&line, "{\"event\":\"sample\"");
        field(&line, "index", i); field(&line, "monotonic_ns", now_ns);
        field(&line, "port", port);
        signed_field(&line, "poll_result", polled < 0 ? -1 : polled);
        field(&line, "poll_errno", positive_errno(polled)); field(&line, "revents", revents);
        signed_field(&line, "accept_result", accepted < 0 ? -1 : accepted);
        field(&line, "accept_errno", positive_errno(accepted));
        field(&line, "accepted_close_errno", positive_errno(accepted_close));
        field(&line, "getsockname_errno", positive_errno(named));
        field(&line, "so_type_errno", positive_errno(typed)); signed_field(&line, "so_type", type);
        field(&line, "so_acceptconn_errno", positive_errno(accept_option));
        signed_field(&line, "so_acceptconn", accepting);
        field(&line, "fcntl_errno", positive_errno(flags)); signed_field(&line, "fcntl_flags", flags);
        okay = emit((int) log, &line); samples++;
        if (accepted_close < 0) okay = 0;
        if (!okay) break;
        struct linux_timespec request = {1, 0}, remaining = {0, 0};
        // No more than eight EINTR retries per second; never busy-poll.
        for (unsigned retry = 0; retry < 8; retry++) {
            s64 slept = sleep_remaining(&request, &remaining);
            if (!slept) break;
            if (slept != -4) { okay = 0; break; }
            request = remaining;
            if (retry == 7) okay = 0;
        }
    }
    s64 listener_close = listener >= 0 ? close_fd((int) listener) : 0;
    line.used = 0; append(&line, "{\"event\":\"end\"");
    field(&line, "samples", samples); field(&line, "setup_ok", setup_ok);
    field(&line, "completed_without_io_error", okay);
    field(&line, "listener_close_errno", positive_errno(listener_close));
    if (!emit((int) log, &line)) okay = 0;
    s64 log_close = close_fd((int) log);
    return setup_ok && okay && listener_close == 0 && log_close == 0 ? 0 : 4;
}

#ifdef __APPLE__
int main(int argc, char **argv) { return probe_main(argc, argv); }
#else
__attribute__((used)) int probe_start(u64 *stack) {
    return probe_main((int) stack[0], (char **) (stack + 1));
}
__asm__(".text\n.globl _start\n.type _start,%function\n_start:\n"
        "mov x0,sp\nbl probe_start\nmov x8,#93\nsvc #0\nb .\n"
        ".size _start,.-_start\n");
#endif
