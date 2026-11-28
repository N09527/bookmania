// The app's side of the embedded Java VM that runs the extension host (docs/extensions-and-sync/design.md, E-1):
// starts the VM, registers the host's native callbacks and passes requests to it. The VM (Eclipse OpenJ9, interpreter
// only) and the host come from the Oneechan runtime (ios/Vendor/oneechan-runtime); they are in the app only when it
// is built with the package of .github/workflows/ios-jvm.yml (BM_HAS_JVM).
#ifndef BM_JVM_H
#define BM_JVM_H

#include <stddef.h>
#include <stdint.h>

/// The host's calls into the app. They come on the host's threads; a buffer is valid only during the call.
typedef struct {
    void *context;
    /// The answer to request `request_id` (a JSON-RPC reply).
    void (*complete)(void *context, int64_t request_id, const uint8_t *bytes, size_t length);
    /// An event of the host (JSON).
    void (*emit)(void *context, const uint8_t *bytes, size_t length);
    /// An extension's HTTP request `id`: its metadata (JSON) and its body, if it has one (`has_body`).
    void (*fetch)(void *context, int64_t id, const uint8_t *meta, size_t meta_length, const uint8_t *body, size_t body_length,
                  int has_body);
    /// The answer to request `id` is no longer needed.
    void (*fetch_cancel)(void *context, int64_t id);
} bm_jvm_callbacks;

/// 1 when this build of the app contains the VM.
int bm_jvm_included(void);

/// Starts the VM with `options` (JavaVMOption strings) and the host with `config` (JSON), once. Waits until the host
/// has started. Returns 0, or -1 with a message in `error`.
int bm_jvm_start(const char *const *options, int option_count, const uint8_t *config, size_t config_length,
                 bm_jvm_callbacks callbacks, char *error, size_t error_size);

/// Queues a request for the host (its answer comes through `complete`). Returns 0, or -1 when the host is not running.
int bm_jvm_call(int64_t request_id, const uint8_t *request, size_t length);

/// Queues the app's answer to the extension HTTP request `id`. Returns 0, or -1 when the host is not running.
int bm_jvm_fetch_result(int64_t id, const uint8_t *meta, size_t meta_length, const uint8_t *body, size_t body_length,
                        int has_body);

#endif
