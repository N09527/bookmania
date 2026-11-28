// The app's side of the embedded Java VM (bm_jvm.h). jni/ holds OpenJDK 21's jni.h and jni_md.h, unchanged
// (GPL-2.0-only with the Classpath Exception).
//
// One thread of its own (8 MB of stack) creates the VM, starts the host, and then makes every call into it from a
// queue: a thread has to be attached to the VM to call it, and the app's own threads come and go. The host calls back
// on its own threads through the natives registered here.
#include "bm_jvm.h"

#include "jni/jni.h"

#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BRIDGE_CLASS "oneechan/host/embedded/EmbeddedBridge"

#if BM_HAS_JVM
// Linked in statically with the VM (jvm.xcconfig of the runtime's package).
JNIIMPORT jint JNICALL JNI_CreateJavaVM(JavaVM **vm, void **env, void *args);
#endif

int bm_jvm_included(void) {
#if BM_HAS_JVM
    return 1;
#else
    return 0;
#endif
}

// MARK: State

enum { STATE_NONE, STATE_STARTING, STATE_RUNNING, STATE_FAILED };
enum { WORK_CALL, WORK_FETCH_RESULT };

typedef struct work {
    int kind;
    int64_t id;
    uint8_t *first;
    size_t first_length;
    uint8_t *second;
    size_t second_length;
    int has_second;
    struct work *next;
} work;

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static int state = STATE_NONE;
static char failure[1024];
static work *queue_head, *queue_tail;
static bm_jvm_callbacks app;

#if BM_HAS_JVM
static jclass bridge;
static jmethodID start_method, call_method, fetch_result_method;
#endif

typedef struct {
    char **options;
    int option_count;
    uint8_t *config;
    size_t config_length;
} start_request;

static void fail(const char *format, ...) {
    va_list args;
    va_start(args, format);
    pthread_mutex_lock(&lock);
    vsnprintf(failure, sizeof failure, format, args);
    state = STATE_FAILED;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&lock);
    va_end(args);
}

static uint8_t *copy(const uint8_t *bytes, size_t length) {
    uint8_t *out = malloc(length ? length : 1);
    if (out && length) memcpy(out, bytes, length);
    return out;
}

static char *copy_string(const char *text) {
    size_t length = strlen(text) + 1;
    char *out = malloc(length);
    if (out) memcpy(out, text, length);
    return out;
}

#if BM_HAS_JVM
// MARK: Calls from the host

static void JNICALL native_complete(JNIEnv *env, jclass cls, jlong id, jbyteArray response) {
    (void)cls;
    if (!response || !app.complete) return;
    jsize length = (*env)->GetArrayLength(env, response);
    jbyte *bytes = (*env)->GetByteArrayElements(env, response, NULL);
    if (!bytes) return;
    app.complete(app.context, (int64_t)id, (const uint8_t *)bytes, (size_t)length);
    (*env)->ReleaseByteArrayElements(env, response, bytes, JNI_ABORT);
}

static void JNICALL native_emit(JNIEnv *env, jclass cls, jbyteArray event) {
    (void)cls;
    if (!event || !app.emit) return;
    jsize length = (*env)->GetArrayLength(env, event);
    jbyte *bytes = (*env)->GetByteArrayElements(env, event, NULL);
    if (!bytes) return;
    app.emit(app.context, (const uint8_t *)bytes, (size_t)length);
    (*env)->ReleaseByteArrayElements(env, event, bytes, JNI_ABORT);
}

static void JNICALL native_fetch(JNIEnv *env, jclass cls, jlong id, jbyteArray meta, jbyteArray body) {
    (void)cls;
    if (!meta || !app.fetch) return;
    jsize meta_length = (*env)->GetArrayLength(env, meta);
    jbyte *meta_bytes = (*env)->GetByteArrayElements(env, meta, NULL);
    if (!meta_bytes) return;
    jsize body_length = body ? (*env)->GetArrayLength(env, body) : 0;
    jbyte *body_bytes = body ? (*env)->GetByteArrayElements(env, body, NULL) : NULL;
    app.fetch(app.context, (int64_t)id, (const uint8_t *)meta_bytes, (size_t)meta_length, (const uint8_t *)body_bytes,
              (size_t)body_length, body_bytes != NULL);
    if (body_bytes) (*env)->ReleaseByteArrayElements(env, body, body_bytes, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, meta, meta_bytes, JNI_ABORT);
}

static void JNICALL native_fetch_cancel(JNIEnv *env, jclass cls, jlong id) {
    (void)env;
    (void)cls;
    if (app.fetch_cancel) app.fetch_cancel(app.context, (int64_t)id);
}

// MARK: The VM's thread

/// The pending exception as text (and cleared), for an error message.
static void describe_exception(JNIEnv *env, char *out, size_t size) {
    jthrowable thrown = (*env)->ExceptionOccurred(env);
    if (!thrown) {
        snprintf(out, size, "no exception");
        return;
    }
    (*env)->ExceptionDescribe(env); // the stack trace, to the device's log
    (*env)->ExceptionClear(env);
    jclass object = (*env)->FindClass(env, "java/lang/Object");
    jmethodID to_string = object ? (*env)->GetMethodID(env, object, "toString", "()Ljava/lang/String;") : NULL;
    jstring text = to_string ? (jstring)(*env)->CallObjectMethod(env, thrown, to_string) : NULL;
    const char *chars = text ? (*env)->GetStringUTFChars(env, text, NULL) : NULL;
    snprintf(out, size, "%s", chars ? chars : "an exception that cannot be described");
    if (chars) (*env)->ReleaseStringUTFChars(env, text, chars);
    (*env)->ExceptionClear(env);
}

static jbyteArray byte_array(JNIEnv *env, const uint8_t *bytes, size_t length) {
    jbyteArray array = (*env)->NewByteArray(env, (jsize)length);
    if (array && length) (*env)->SetByteArrayRegion(env, array, 0, (jsize)length, (const jbyte *)bytes);
    return array;
}

static void run(JNIEnv *env, work *item) {
    jbyteArray first = byte_array(env, item->first, item->first_length);
    jbyteArray second = item->has_second ? byte_array(env, item->second, item->second_length) : NULL;
    if (item->kind == WORK_CALL) {
        (*env)->CallStaticVoidMethod(env, bridge, call_method, (jlong)item->id, first);
    } else {
        (*env)->CallStaticVoidMethod(env, bridge, fetch_result_method, (jlong)item->id, first, second);
    }
    if ((*env)->ExceptionCheck(env)) {
        char text[512];
        describe_exception(env, text, sizeof text);
        fprintf(stderr, "bm_jvm: call %lld failed: %s\n", (long long)item->id, text);
    }
    if (first) (*env)->DeleteLocalRef(env, first);
    if (second) (*env)->DeleteLocalRef(env, second);
}
#endif

static void *vm_thread(void *argument) {
    start_request *request = argument;
#if BM_HAS_JVM
    JavaVMOption *options = calloc((size_t)request->option_count, sizeof(JavaVMOption));
    for (int i = 0; i < request->option_count; i++) options[i].optionString = request->options[i];
    JavaVMInitArgs args;
    memset(&args, 0, sizeof args);
    args.version = JNI_VERSION_21;
    args.nOptions = request->option_count;
    args.options = options;
    args.ignoreUnrecognized = JNI_FALSE;
    JavaVM *vm = NULL;
    JNIEnv *env = NULL;
    jint created = JNI_CreateJavaVM(&vm, (void **)&env, &args);
    free(options);
    if (created != JNI_OK || !env) {
        fail("The Java VM did not start (JNI_CreateJavaVM: %d).", (int)created);
        return NULL;
    }
    jclass found = (*env)->FindClass(env, BRIDGE_CLASS);
    if (!found) {
        char text[512];
        describe_exception(env, text, sizeof text);
        fail("The extension host's bridge was not found: %s", text);
        return NULL;
    }
    bridge = (jclass)(*env)->NewGlobalRef(env, found);
    JNINativeMethod natives[] = {
        {"complete", "(J[B)V", (void *)native_complete},
        {"emit", "([B)V", (void *)native_emit},
        {"fetch", "(J[B[B)V", (void *)native_fetch},
        {"fetchCancel", "(J)V", (void *)native_fetch_cancel},
    };
    if ((*env)->RegisterNatives(env, bridge, natives, 4) != JNI_OK) {
        char text[512];
        describe_exception(env, text, sizeof text);
        fail("The extension host's natives could not be registered: %s", text);
        return NULL;
    }
    start_method = (*env)->GetStaticMethodID(env, bridge, "start", "([B)Ljava/lang/String;");
    call_method = (*env)->GetStaticMethodID(env, bridge, "call", "(J[B)V");
    fetch_result_method = (*env)->GetStaticMethodID(env, bridge, "fetchResult", "(J[B[B)V");
    if (!start_method || !call_method || !fetch_result_method) {
        char text[512];
        describe_exception(env, text, sizeof text);
        fail("The extension host's bridge is not the expected one: %s", text);
        return NULL;
    }
    jbyteArray config = byte_array(env, request->config, request->config_length);
    jstring problem = (jstring)(*env)->CallStaticObjectMethod(env, bridge, start_method, config);
    if ((*env)->ExceptionCheck(env)) {
        char text[512];
        describe_exception(env, text, sizeof text);
        fail("The extension host did not start: %s", text);
        return NULL;
    }
    if (problem) {
        const char *chars = (*env)->GetStringUTFChars(env, problem, NULL);
        fail("The extension host did not start: %s", chars ? chars : "?");
        if (chars) (*env)->ReleaseStringUTFChars(env, problem, chars);
        return NULL;
    }
    (*env)->DeleteLocalRef(env, config);

    pthread_mutex_lock(&lock);
    state = STATE_RUNNING;
    pthread_cond_broadcast(&changed);
    for (;;) {
        while (!queue_head) pthread_cond_wait(&changed, &lock);
        work *item = queue_head;
        queue_head = item->next;
        if (!queue_head) queue_tail = NULL;
        pthread_mutex_unlock(&lock);
        run(env, item);
        free(item->first);
        free(item->second);
        free(item);
        pthread_mutex_lock(&lock);
    }
#else
    (void)request;
    fail("This build of the app does not contain the extension runtime.");
    return NULL;
#endif
}

// MARK: The app's calls

int bm_jvm_start(const char *const *options, int option_count, const uint8_t *config, size_t config_length,
                 bm_jvm_callbacks callbacks, char *error, size_t error_size) {
    pthread_mutex_lock(&lock);
    if (state == STATE_NONE) {
        state = STATE_STARTING;
        app = callbacks;
        // Kept for the VM's lifetime: it may read its options after starting.
        start_request *request = calloc(1, sizeof *request);
        request->options = calloc((size_t)option_count, sizeof(char *));
        for (int i = 0; i < option_count; i++) request->options[i] = copy_string(options[i]);
        request->option_count = option_count;
        request->config = copy(config, config_length);
        request->config_length = config_length;
        pthread_attr_t attributes;
        pthread_attr_init(&attributes);
        pthread_attr_setstacksize(&attributes, 8 * 1024 * 1024);
        pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
        pthread_t thread;
        if (pthread_create(&thread, &attributes, vm_thread, request) != 0) {
            snprintf(failure, sizeof failure, "The Java VM's thread could not be created.");
            state = STATE_FAILED;
        }
        pthread_attr_destroy(&attributes);
    }
    while (state == STATE_STARTING) pthread_cond_wait(&changed, &lock);
    int result = state == STATE_RUNNING ? 0 : -1;
    if (result != 0 && error && error_size) snprintf(error, error_size, "%s", failure);
    pthread_mutex_unlock(&lock);
    return result;
}

static int enqueue(int kind, int64_t id, const uint8_t *first, size_t first_length, const uint8_t *second,
                   size_t second_length, int has_second) {
    work *item = calloc(1, sizeof *item);
    if (!item) return -1;
    item->kind = kind;
    item->id = id;
    item->first = copy(first, first_length);
    item->first_length = first_length;
    item->has_second = has_second;
    if (has_second) {
        item->second = copy(second, second_length);
        item->second_length = second_length;
    }
    pthread_mutex_lock(&lock);
    if (state != STATE_RUNNING) {
        pthread_mutex_unlock(&lock);
        free(item->first);
        free(item->second);
        free(item);
        return -1;
    }
    if (queue_tail) queue_tail->next = item; else queue_head = item;
    queue_tail = item;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&lock);
    return 0;
}

int bm_jvm_call(int64_t request_id, const uint8_t *request, size_t length) {
    return enqueue(WORK_CALL, request_id, request, length, NULL, 0, 0);
}

int bm_jvm_fetch_result(int64_t id, const uint8_t *meta, size_t meta_length, const uint8_t *body, size_t body_length,
                        int has_body) {
    return enqueue(WORK_FETCH_RESULT, id, meta, meta_length, body, body_length, has_body);
}
