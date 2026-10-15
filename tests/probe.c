/* probe.c - the harness's interposer. tests/dot.f compiles it with cc once per
 * run into the run's root, and RUN-PROBE and RUN-PINNED preload it into bin/dot
 * through DYLD_INSERT_LIBRARIES on macOS or LD_PRELOAD on Linux.
 *
 * DOTS_PROBE_RENAME=<dst> DOTS_PROBE_MOVED=<path>: a no-replace rename
 * (renamex_np on macOS, renameat2 on Linux) whose destination ends with <dst>
 * fails with EACCES once <path> no longer exists. Until dot has moved <path>
 * away the rename goes through, so the failure only ever strikes mid-commit.
 *
 * DOTS_PROBE_RANDOM=<hex>: arc4random_buf fills its buffer with the bytes the
 * hex digits spell, repeated, so add's random suffix is known. Hex that is
 * empty, odd in length or holds a non-hex digit aborts. Unset, arc4random_buf
 * is the system's.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int should_fail(const char *dst) {
    const char *want = getenv("DOTS_PROBE_RENAME");
    const char *moved = getenv("DOTS_PROBE_MOVED");
    if (!want || !moved) return 0;
    size_t n = strlen(dst), m = strlen(want);
    if (n < m || strcmp(dst + n - m, want) != 0) return 0;
    if (access(moved, F_OK) == 0) return 0;
    errno = EACCES;
    return 1;
}

static int hex_digit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Fill buf from DOTS_PROBE_RANDOM; answers 0 when it is unset. */
static int pinned_fill(void *buf, size_t len) {
    const char *hex = getenv("DOTS_PROBE_RANDOM");
    if (!hex) return 0;
    size_t n = strlen(hex);
    if (n == 0 || n % 2 != 0) abort();
    for (size_t i = 0; i < n; i++)
        if (hex_digit(hex[i]) < 0) abort();
    size_t bytes = n / 2;
    for (size_t i = 0; i < len; i++) {
        const char *pair = hex + 2 * (i % bytes);
        ((unsigned char *)buf)[i] =
            (unsigned char)(hex_digit(pair[0]) << 4 | hex_digit(pair[1]));
    }
    return 1;
}

#if defined(__APPLE__)
#include <stdint.h>
#include <stdio.h>

static int probe_renamex(const char *src, const char *dst, unsigned int flags) {
    if (should_fail(dst)) return -1;
    return renamex_np(src, dst, flags);
}

static void probe_random(void *buf, size_t len) {
    if (!pinned_fill(buf, len)) arc4random_buf(buf, len);
}

__attribute__((used)) static struct { const void *with; const void *of; }
    interpose[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)(uintptr_t)&probe_renamex, (const void *)(uintptr_t)&renamex_np },
    { (const void *)(uintptr_t)&probe_random, (const void *)(uintptr_t)&arc4random_buf },
};

#elif defined(__linux__)
#include <dlfcn.h>
#include <stdio.h>

int renameat2(int olddirfd, const char *src, int newdirfd, const char *dst,
              unsigned int flags) {
    if (should_fail(dst)) return -1;
    int (*next)(int, const char *, int, const char *, unsigned int) =
        (int (*)(int, const char *, int, const char *, unsigned int))
            dlsym(RTLD_NEXT, "renameat2");
    return next(olddirfd, src, newdirfd, dst, flags);
}

void arc4random_buf(void *buf, size_t len) {
    if (pinned_fill(buf, len)) return;
    void (*next)(void *, size_t) =
        (void (*)(void *, size_t))dlsym(RTLD_NEXT, "arc4random_buf");
    next(buf, len);
}

#else
#error "tests/probe.c interposes rename and arc4random_buf on macOS and Linux only"
#endif
