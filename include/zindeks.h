/* zindeks.h — checked C ABI for the in-process zindeks engine.
 *
 * ABI version 1.
 *
 * The host (e.g. the Kode editor) loads this shared library and drives the
 * existing JSON-RPC engine in-process: no spawned CLI, no MCP server, no TCP
 * port.  Requests and responses are the same JSON-RPC messages the stdio MCP
 * server speaks; only the framing is removed.
 *
 * Threading / lifetime rules:
 *   - A handle may be used from multiple threads; the library serializes
 *     requests internally.  Do not call zindeks_close() while any request is
 *     in flight on the same handle.
 *   - Every buffer returned through ZindeksBuffer is owned by the library.
 *     Release it with zindeks_buffer_free().  zindeks_buffer_free() accepts
 *     an already-cleared buffer and zindeks_close() accepts NULL.
 *   - Never free a pointer the library did not return through ZindeksBuffer.
 */
#ifndef ZINDEKS_H
#define ZINDEKS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define ZINDEKS_API __declspec(dllimport)
#else
#define ZINDEKS_API
#endif

/* Opaque handle bound to one repository. */
typedef struct ZindeksHandle ZindeksHandle;

/* Library-owned byte buffer.  `ptr` is NULL and `len` is 0 when empty. */
typedef struct ZindeksBuffer {
    unsigned char *ptr;
    size_t len;
} ZindeksBuffer;

/* Status codes returned by zindeks_open() and zindeks_request(). */
#define ZINDEKS_STATUS_OK 0
#define ZINDEKS_STATUS_INVALID_INPUT 1
#define ZINDEKS_STATUS_INIT_ERROR 2
#define ZINDEKS_STATUS_ALLOC_ERROR 3
#define ZINDEKS_STATUS_BUSY 4

/* Maximum accepted request body (1 MiB). */
#define ZINDEKS_MAX_REQUEST_BYTES (1u << 20)
/* Maximum produced response body (16 MiB). */
#define ZINDEKS_MAX_RESPONSE_BYTES (16u * 1024u * 1024u)

/* Returns the ABI version implemented by this library (always 1 here). */
ZINDEKS_API uint32_t zindeks_abi_version(void);

/*
 * Open a handle for `options` (UTF-8 JSON, `len` bytes; not NUL-terminated):
 *
 *   {
 *     "repository": "<absolute canonical repository path>",  // required
 *     "store_root": "<absolute index store path>",           // optional
 *     "watch": true                                          // optional
 *   }
 *
 * The options are copied; the caller retains ownership of the input bytes.
 * One handle is bound to one repository.  No process CWD or environment is
 * consulted or mutated.
 *
 * On success *out holds a handle and *error is cleared.
 * On failure *out is set to NULL and, when it can be allocated, *error holds
 * an owned UTF-8 JSON error object: {"status":N,"message":"..."}.
 * Outputs are initialized before any work.  Both *out and *error may be
 * non-NULL; passing NULL for *out is allowed (validation only).
 */
ZINDEKS_API int32_t zindeks_open(const unsigned char *options, size_t len,
                                 ZindeksHandle **out, ZindeksBuffer *error);

/*
 * Execute one raw JSON-RPC message (UTF-8, `len` bytes).
 *
 * On success *response holds the raw JSON-RPC response body and the return
 * value is ZINDEKS_STATUS_OK.  A JSON-RPC notification succeeds with an empty
 * response (ptr NULL, len 0).  A tool-level error is returned inside the
 * JSON-RPC response (`error` / `result.isError`); it is NOT an ABI error.
 *
 * `response` must be non-NULL and is initialized before any work.
 */
ZINDEKS_API int32_t zindeks_request(ZindeksHandle *handle,
                                    const unsigned char *json, size_t len,
                                    ZindeksBuffer *response);

/* Release a buffer returned by zindeks_open() or zindeks_request(). */
ZINDEKS_API void zindeks_buffer_free(ZindeksBuffer *buffer);

/* Close a handle and release all of its resources.  Accepts NULL. */
ZINDEKS_API void zindeks_close(ZindeksHandle *handle);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ZINDEKS_H */
