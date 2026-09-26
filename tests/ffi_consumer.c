/*
 * zindeks C ABI smoke test.
 *
 * Compiled by `zig build ffi-test` against include/zindeks.h and the shared
 * library, then executed.  Exercises the ABI contract: version, open with
 * valid/invalid options, request dispatch, notifications, invalid input,
 * buffer ownership and close semantics.
 *
 * Exit code 0 = all checks passed.
 */
#include "zindeks.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <direct.h>
#include <process.h>
#define Z_MKDIR(p) _mkdir(p)
#define Z_GETPID() _getpid()
#else
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#define Z_MKDIR(p) mkdir((p), 0700)
#define Z_GETPID() getpid()
#endif

static int failures = 0;

#define CHECK(cond, msg)                                                        \
    do {                                                                        \
        if (!(cond)) {                                                          \
            fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__);   \
            failures++;                                                         \
        }                                                                       \
    } while (0)

static const char *temp_root(void) {
    const char *t = getenv("TEMP");
    if (t == NULL || t[0] == '\0') t = getenv("TMP");
    if (t == NULL || t[0] == '\0') t = getenv("TMPDIR");
    if (t == NULL || t[0] == '\0') t = "/tmp";
    return t;
}

static int request_ok(ZindeksHandle *h, const char *json, ZindeksBuffer *out) {
    int32_t rc = zindeks_request(h, (const unsigned char *)json, strlen(json), out);
    return rc == ZINDEKS_STATUS_OK;
}

int main(void) {
    CHECK(zindeks_abi_version() == 1, "abi version is 1");

    /* Invalid options. */
    {
        ZindeksHandle *h = (ZindeksHandle *)0x1;
        ZindeksBuffer err = {0};
        int32_t rc = zindeks_open(NULL, 0, &h, &err);
        CHECK(rc == ZINDEKS_STATUS_INVALID_INPUT, "null options rejected");
        CHECK(h == NULL, "failed open yields no handle");
        CHECK(err.ptr != NULL && err.len > 0, "failed open yields error bytes");
        zindeks_buffer_free(&err);
        CHECK(err.ptr == NULL && err.len == 0, "buffer_free clears struct");
    }

    /* Build a temporary repository + store. */
    char repo[1024];
    char store[1024];
    char options[2200];
    snprintf(repo, sizeof(repo), "%s/zindeks_ffi_%d", temp_root(), (int)Z_GETPID());
    snprintf(store, sizeof(store), "%s/zindeks_ffi_store_%d", temp_root(), (int)Z_GETPID());
    Z_MKDIR(repo);
    Z_MKDIR(store);
    snprintf(options, sizeof(options),
             "{\"repository\":\"%s\",\"store_root\":\"%s\"}", repo, store);
    /* JSON-escape Windows separators (also valid on POSIX). */
    for (char *p = options; *p != '\0'; p++) {
        if (*p == '\\') *p = '/';
    }

    ZindeksHandle *handle = NULL;
    ZindeksBuffer err = {0};
    int32_t rc = zindeks_open((const unsigned char *)options, strlen(options), &handle, &err);
    if (rc != ZINDEKS_STATUS_OK) {
        fprintf(stderr, "FAIL: open returned %d: %.*s\n", rc, (int)err.len, (char *)err.ptr);
        failures++;
        zindeks_buffer_free(&err);
    } else {
        CHECK(handle != NULL, "open yields a handle");
    }

    /* Null handle request. */
    {
        ZindeksBuffer resp = {0};
        CHECK(zindeks_request(NULL, (const unsigned char *)"{}", 2, &resp) ==
                  ZINDEKS_STATUS_INVALID_INPUT,
              "null handle rejected");
    }

    if (handle != NULL) {
        ZindeksBuffer resp = {0};

        CHECK(request_ok(handle,
                         "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\","
                         "\"params\":{\"protocolVersion\":\"2024-11-05\"}}",
                         &resp),
              "initialize succeeds");
        CHECK(resp.ptr != NULL && resp.len > 0, "initialize yields a response");
        zindeks_buffer_free(&resp);

        CHECK(request_ok(handle, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}", &resp),
              "tools/list succeeds");
        CHECK(resp.ptr != NULL && resp.len > 0, "tools/list yields a response");
        zindeks_buffer_free(&resp);

        CHECK(request_ok(handle,
                         "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\","
                         "\"params\":{\"name\":\"list_projects\",\"arguments\":{}}}",
                         &resp),
              "tools/call succeeds");
        zindeks_buffer_free(&resp);

        /* Notification: no id -> empty response, success status. */
        {
            const char *note = "{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}";
            ZindeksBuffer n = {0};
            int32_t nrc = zindeks_request(handle, (const unsigned char *)note, strlen(note), &n);
            CHECK(nrc == ZINDEKS_STATUS_OK, "notification succeeds");
            CHECK(n.ptr == NULL && n.len == 0, "notification has empty response");
            zindeks_buffer_free(&n);
        }

        /* Invalid JSON -> invalid input, no response bytes. */
        {
            ZindeksBuffer b = {0};
            int32_t brc = zindeks_request(handle, (const unsigned char *)"{not json", 9, &b);
            CHECK(brc == ZINDEKS_STATUS_INVALID_INPUT, "invalid json rejected");
            CHECK(b.ptr == NULL, "invalid json leaves response empty");
        }

        /* Oversize request rejected before dispatch. */
        {
            size_t big = ZINDEKS_MAX_REQUEST_BYTES + 1;
            unsigned char *buf = (unsigned char *)malloc(big);
            if (buf != NULL) {
                memset(buf, ' ', big);
                ZindeksBuffer b = {0};
                int32_t brc = zindeks_request(handle, buf, big, &b);
                CHECK(brc == ZINDEKS_STATUS_INVALID_INPUT, "oversize request rejected");
                free(buf);
            }
        }

        /* 100 open/request/close cycles release resources. */
        for (int i = 0; i < 100; i++) {
            ZindeksHandle *h2 = NULL;
            ZindeksBuffer e2 = {0};
            int32_t orc = zindeks_open((const unsigned char *)options, strlen(options), &h2, &e2);
            if (orc != ZINDEKS_STATUS_OK) {
                failures++;
                zindeks_buffer_free(&e2);
                break;
            }
            ZindeksBuffer r2 = {0};
            const char *ping = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}";
            (void)zindeks_request(h2, (const unsigned char *)ping, strlen(ping), &r2);
            zindeks_buffer_free(&r2);
            zindeks_close(h2);
        }

        zindeks_close(handle);
    }

    zindeks_close(NULL);
    zindeks_buffer_free(NULL);

    if (failures == 0) {
        printf("ffi_consumer: all checks passed\n");
        return 0;
    }
    fprintf(stderr, "ffi_consumer: %d check(s) failed\n", failures);
    return 1;
}
