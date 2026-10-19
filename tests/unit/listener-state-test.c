// Bounded native-host diagnostic using production readiness and wait paths.
// Socket creation, mutation, and accept use host POSIX APIs. Lifecycle hooks
// below are no-ops: this does not exercise the guest socket or restart layer.
// Invalid states below are deliberate local mutations, not iOS revocation.
#include <arpa/inet.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include "kernel/task.h"
#include "fs/fd.h"
#include "fs/poll.h"
#include "fs/real.h"

__thread struct task *current;
int errno_map(void) { return -errno; }
bool is_adhoc_fd(struct fd *fd) { (void) fd; return false; }
void sockrestart_begin_listen_wait(struct fd *fd) { (void) fd; }
void sockrestart_end_listen_wait(struct fd *fd) { (void) fd; }
bool sockrestart_should_restart_listen_wait(void) { return false; }
void ish_printk(const char *format, ...) {
    va_list args;
    va_start(args, format);
    vfprintf(stderr, format, args);
    va_end(args);
}

#define CHECK(test) do { \
    if (!(test)) { \
        fprintf(stderr, "listener-state-test:%d: %s (errno %d)\n", \
                __LINE__, #test, errno); \
        exit(1); \
    } \
} while (0)

static double wall_time(void) {
    struct timespec ts;
    CHECK(clock_gettime(CLOCK_MONOTONIC, &ts) == 0);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static double cpu_time(void) {
    struct rusage usage;
    CHECK(getrusage(RUSAGE_SELF, &usage) == 0);
    return usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 +
        usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6;
}

static const struct fd_ops native_ops = {.poll = realfs_poll};

static void fd_init(struct fd *fd, int host_fd) {
    memset(fd, 0, sizeof(*fd));
    fd->real_fd = host_fd;
    fd->type = S_IFSOCK;
    fd->ops = &native_ops;
    list_init(&fd->poll_fds);
    lock_init(&fd->poll_lock);
}

static int new_bound_socket(struct sockaddr_in *address, bool listening) {
    int host_fd = socket(AF_INET, SOCK_STREAM, 0);
    CHECK(host_fd >= 0);
    CHECK(fcntl(host_fd, F_SETFL, O_NONBLOCK) == 0);
    *address = (struct sockaddr_in) {
        .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
    };
    CHECK(bind(host_fd, (struct sockaddr *) address, sizeof(*address)) == 0);
    socklen_t length = sizeof(*address);
    CHECK(getsockname(host_fd, (struct sockaddr *) address, &length) == 0);
    if (listening)
        CHECK(listen(host_fd, 4) == 0);
    return host_fd;
}

static struct poll *new_poll(struct fd *member) {
    struct poll *poll = poll_create();
    CHECK(!IS_ERR(poll));
    CHECK(poll_add_fd(poll, member, POLL_READ | POLL_HUP | POLL_ERR,
                (union poll_fd_info) {0}) == 0);
    return poll;
}

static int count_event(void *context, int types, union poll_fd_info info) {
    (void) info;
    *(int *) context |= types;
    return 1;
}

static int wait_ms(struct poll *poll, int milliseconds, int *events) {
    struct timespec timeout = {.tv_nsec = milliseconds * 1000000L};
    *events = 0;
    return poll_wait(poll, count_event, events, &timeout);
}

static void snapshot(const char *name, const char *phase, struct fd *fd,
        bool probe_accept) {
    int accepting = -1;
    socklen_t length = sizeof(accepting);
    errno = 0;
    int option_result = getsockopt(fd->real_fd, SOL_SOCKET, SO_ACCEPTCONN,
            &accepting, &length);
    int option_errno = option_result < 0 ? errno : 0;
    // Record even an unsupported SO_ACCEPTCONN; a host may reject this option
    // on a listener whose accept control succeeds, so it is not a pass gate.
    struct sockaddr_in address = {0};
    length = sizeof(address);
    errno = 0;
    int address_result = getsockname(fd->real_fd,
            (struct sockaddr *) &address, &length);
    int address_errno = address_result < 0 ? errno : 0;
    struct pollfd native = {.fd = fd->real_fd, .events = POLLIN};
    errno = 0;
    int poll_result = poll(&native, 1, 0);
    int poll_errno = poll_result < 0 ? errno : 0;
    int readiness = realfs_poll(fd);
    int accept_result = -1, accept_errno = 0;
    if (probe_accept) {
        errno = 0;
        accept_result = accept(fd->real_fd, NULL, NULL);
        accept_errno = accept_result < 0 ? errno : 0;
        if (accept_result >= 0)
            CHECK(close(accept_result) == 0);
    }
    printf("{\"case\":\"%s\",\"phase\":\"%s\","
            "\"acceptconn_result\":%d,\"acceptconn_errno\":%d,"
            "\"acceptconn\":%d,\"getsockname_result\":%d,"
            "\"getsockname_errno\":%d,\"family\":%d,"
            "\"port\":%u,\"native_poll_result\":%d,\"native_poll_errno\":%d,"
            "\"native_poll_revents\":%d,\"production_readiness\":%d,"
            "\"accept_probed\":%s,\"accept_result\":%d,\"accept_errno\":%d}\n",
            name, phase, option_result, option_errno, accepting, address_result,
            address_errno, address.sin_family, ntohs(address.sin_port), poll_result,
            poll_errno, native.revents, readiness, probe_accept ? "true" : "false",
            accept_result, accept_errno);
}

static void valid_control(void) {
    struct sockaddr_in address;
    int host_fd = new_bound_socket(&address, true);
    struct fd member;
    fd_init(&member, host_fd);
    struct poll *poll = new_poll(&member);
    snapshot("valid", "idle", &member, true);
    int events;
    double wall_start = wall_time(), cpu_start = cpu_time();
    CHECK(wait_ms(poll, 200, &events) == 0);
    double elapsed = wall_time() - wall_start, cpu = cpu_time() - cpu_start;
    CHECK(events == 0 && elapsed >= 0.15 && elapsed < 1.5);
    CHECK(cpu < elapsed / 2);
    printf("{\"case\":\"valid\",\"phase\":\"idle_wait\","
            "\"wall_seconds\":%.6f,\"cpu_seconds\":%.6f}\n", elapsed, cpu);
    int client = socket(AF_INET, SOCK_STREAM, 0);
    CHECK(client >= 0);
    CHECK(connect(client, (struct sockaddr *) &address, sizeof(address)) == 0);
    CHECK(wait_ms(poll, 200, &events) == 1);
    CHECK(events & POLL_READ);
    snapshot("valid", "connected", &member, false);
    int accepted = accept(host_fd, NULL, NULL);
    CHECK(accepted >= 0);
    puts("{\"case\":\"valid\",\"phase\":\"accept\",\"succeeded\":true,\"errno\":0}");
    CHECK(close(accepted) == 0);
    CHECK(close(client) == 0);
    CHECK(wait_ms(poll, 0, &events) == 0 && events == 0);
    snapshot("valid", "accepted", &member, true);
    poll_destroy(poll);
    CHECK(close(host_fd) == 0);
}

enum mutation { SHUT_DOWN, NEVER_LISTENED, REPLACED_WITH_NULL };

static void abnormal_case(const char *name, enum mutation mutation) {
    struct sockaddr_in address;
    int host_fd = new_bound_socket(&address, mutation != NEVER_LISTENED);
    struct fd member;
    fd_init(&member, host_fd);
    snapshot(name, "before", &member, true);
    int mutation_result = 0, mutation_errno = 0;
    if (mutation == SHUT_DOWN) {
        mutation_result = shutdown(host_fd, SHUT_RDWR);
        mutation_errno = mutation_result < 0 ? errno : 0;
    } else if (mutation == REPLACED_WITH_NULL) {
        int replacement = open("/dev/null", O_RDONLY);
        CHECK(replacement >= 0 && replacement != host_fd);
        mutation_result = dup2(replacement, host_fd);
        mutation_errno = mutation_result < 0 ? errno : 0;
        CHECK(close(replacement) == 0);
        CHECK(mutation_result == host_fd);
    }
    printf("{\"case\":\"%s\",\"phase\":\"mutation\","
            "\"result\":%d,\"errno\":%d}\n", name, mutation_result, mutation_errno);
    snapshot(name, "after", &member, true);
    struct poll *poll = new_poll(&member);
    int ready_waits = 0, accept_failures = 0, last_accept_errno = 0;
    int last_wait = 0, combined_events = 0;
    const int iterations = 20;
    double wall_start = wall_time(), cpu_start = cpu_time();
    for (int i = 0; i < iterations; i++) {
        int events;
        last_wait = wait_ms(poll, 20, &events);
        combined_events |= events;
        if (last_wait > 0)
            ready_waits++;
        errno = 0;
        int accepted = accept(host_fd, NULL, NULL);
        if (accepted < 0) {
            accept_failures++;
            last_accept_errno = errno;
        } else {
            CHECK(close(accepted) == 0);
        }
    }
    printf("{\"case\":\"%s\",\"phase\":\"bounded_loop\","
            "\"iterations\":%d,\"ready_waits\":%d,\"last_wait\":%d,"
            "\"combined_events\":%d,\"accept_failures\":%d,"
            "\"last_accept_errno\":%d,\"wall_seconds\":%.6f,"
            "\"cpu_seconds\":%.6f}\n", name, iterations, ready_waits,
            last_wait, combined_events, accept_failures, last_accept_errno,
            wall_time() - wall_start, cpu_time() - cpu_start);
    // All three states have no pending connection. Do not assert particular
    // invalid-state errnos or readiness bits across different host kernels.
    CHECK(accept_failures == iterations);
    poll_destroy(poll);
    CHECK(close(host_fd) == 0);
}

static int run_case(const char *name, int mutation) {
    pid_t child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        alarm(3); // Bounds even a production poll_wait internal loop.
        if (mutation < 0)
            valid_control();
        else
            abnormal_case(name, mutation);
        _exit(0);
    }
    int status;
    CHECK(waitpid(child, &status, 0) == child);
    bool passed = WIFEXITED(status) && WEXITSTATUS(status) == 0;
    printf("{\"case\":\"%s\",\"phase\":\"child_exit\","
            "\"passed\":%s,\"exit_code\":%d,\"signal\":%d}\n",
            name, passed ? "true" : "false",
            WIFEXITED(status) ? WEXITSTATUS(status) : -1,
            WIFSIGNALED(status) ? WTERMSIG(status) : 0);
    return passed ? 0 : 1;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    struct tgroup group = {0};
    struct task task = {.group = &group};
    current = &task;
    // These cases compare host states, not lock/unlock or iOS suspension.
    alarm(15);
    int failures = run_case("valid", -1);
    failures += run_case("shutdown", SHUT_DOWN);
    failures += run_case("bound_not_listening", NEVER_LISTENED);
    failures += run_case("dup2_null", REPLACED_WITH_NULL);
    alarm(0);
    return failures ? 1 : 0;
}
