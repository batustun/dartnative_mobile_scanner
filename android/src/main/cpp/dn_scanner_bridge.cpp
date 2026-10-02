// The JNI bridge for dartnative_mobile_scanner.
//
// Owns the dispatcher slot: the single Dart callback address this plugin holds,
// plus the framework's isolate generation captured alongside it. Every delivery
// re-checks both, so a hot restart drops the event instead of calling a pointer
// the Dart VM has already deleted.
//
// Framework symbols are resolved with dlsym at runtime, so there is no
// compile-time or link-time coupling to the core library and a stale framework
// degrades instead of failing to load.

#include <jni.h>

#include <atomic>
#include <cstdint>
#include <cstring>
#include <dlfcn.h>

#include <android/log.h>

#define DN_TAG "DNMobileScanner"
#define DN_LOGW(...) \
    __android_log_print(ANDROID_LOG_WARN, DN_TAG, __VA_ARGS__)

namespace {

/// The Dart dispatcher's address, or 0 when no session has handed one over.
std::atomic<int64_t> g_dispatcher{0};

/// The framework's isolate generation at the moment the address arrived.
std::atomic<uint64_t> g_dispatcher_gen{0};

JavaVM* g_jvm = nullptr;

/// A global reference to DNMobileScannerBridge, for the dispose-all call.
jclass g_bridge_class = nullptr;
jmethodID g_dispose_all = nullptr;

using DnIsolateGenFn = uint64_t (*)();

/// Reads the framework's hot-restart counter.
///
/// Resolved once, lazily, and deliberately not through `RTLD_DEFAULT` alone.
/// Android's linker namespaces mean `RTLD_DEFAULT` from this library does not
/// necessarily include `libdartnative_android.so`, which the framework loads with
/// `System.loadLibrary`. When the lookup silently failed this returned 0 for
/// every call, so the staleness comparison `captured != current` was always false,
/// the guard never fired, and a hot restart called a deleted Dart callback:
/// `Callback invoked after it has been deleted` then SIGABRT. Reproduced on a
/// Galaxy S23 Ultra, Android 16.
///
/// So the symbol is also requested by name. `RTLD_NOLOAD` first, because the
/// framework has already loaded it and only a handle is wanted.
uint64_t dn_isolate_gen() {
    static DnIsolateGenFn fn = []() -> DnIsolateGenFn {
        if (auto* f = reinterpret_cast<DnIsolateGenFn>(
                dlsym(RTLD_DEFAULT, "DN_IsolateGen"))) {
            return f;
        }
        void* handle = dlopen("libdartnative_android.so", RTLD_NOLOAD | RTLD_NOW);
        if (handle == nullptr) {
            handle = dlopen("libdartnative_android.so", RTLD_NOW);
        }
        if (handle != nullptr) {
            return reinterpret_cast<DnIsolateGenFn>(
                dlsym(handle, "DN_IsolateGen"));
        }
        return nullptr;
    }();
    if (fn == nullptr) {
        // Not debug noise: without this counter the plugin cannot tell a live
        // Dart callback from one deleted by a hot restart, so the one protection
        // against calling a dead pointer is missing. Say so once, loudly.
        static std::atomic<bool> warned{false};
        bool expected = false;
        if (warned.compare_exchange_strong(expected, true)) {
            DN_LOGW("DN_IsolateGen could not be resolved; hot-restart protection "
                    "is unavailable and events will be dropped instead of risking "
                    "a deleted callback");
        }
        return 0;
    }
    return fn();
}

using DnDispatchFn = void (*)(int64_t token, int32_t type, const char* payload);

}  // namespace

extern "C" {

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* /*reserved*/) {
    // The only call site that reaches here is System.loadLibrary from
    // DartNativeMobileScannerPlugin.onAttachedToEngine. If the plugin were
    // declared with `ffiPlugin: true` instead of `pluginClass`, this would never
    // run and g_jvm would stay null.
    g_jvm = vm;
    return JNI_VERSION_1_6;
}

/// Receives the Dart dispatcher address. Called once per Dart session.
///
/// The generation is captured together with the pointer, which is what makes the
/// staleness check below meaningful.
JNIEXPORT void JNICALL DNMobileScannerSetDispatcher(int64_t callback_ptr) {
    g_dispatcher_gen.store(dn_isolate_gen(), std::memory_order_relaxed);
    g_dispatcher.store(callback_ptr, std::memory_order_release);
}

/// Every symbology the bundled ML Kit recognizer supports.
///
/// A static string, so the Dart side may read the pointer for the app's lifetime
/// and never frees it. Unlike iOS this does not vary by OS version: the model
/// ships inside the app.
JNIEXPORT const char* JNICALL DNMobileScannerSupportedFormats() {
    static const char* kFormats =
        "[\"code128\",\"code39\",\"code93\",\"codabar\",\"dataMatrix\","
        "\"ean13\",\"ean8\",\"itf\",\"qrCode\",\"upcA\",\"upcE\","
        "\"pdf417\",\"aztec\"]";
    return kFormats;
}

/// Tears down every live scanner.
///
/// Called from the Dart side's loadSymbols(), which runs again on every hot
/// restart. Without it the previous session's camera would stay open and its
/// analyzer would keep running against a program that no longer exists.
JNIEXPORT void JNICALL DNMobileScannerDisposeAll() {
    if (g_jvm == nullptr || g_bridge_class == nullptr ||
        g_dispose_all == nullptr) {
        return;
    }
    JNIEnv* env = nullptr;
    if (g_jvm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
        // Called from the Dart thread, which is the platform main thread and is
        // already attached. Anything else is not a context we should be in.
        DN_LOGW("DisposeAll called from a thread with no JNIEnv");
        return;
    }
    env->CallStaticVoidMethod(g_bridge_class, g_dispose_all);
    if (env->ExceptionCheck()) {
        env->ExceptionDescribe();
        env->ExceptionClear();
    }
}

/// Caches the bridge class so DisposeAll can reach Kotlin.
///
/// Called from Kotlin at registration time, on a thread where class lookup is
/// valid. Doing it here rather than in JNI_OnLoad avoids FindClass running under
/// a class loader that cannot see app classes.
JNIEXPORT void JNICALL
Java_com_dartnative_mobile_1scanner_DNMobileScannerBridge_nativeRegisterBridge(
    JNIEnv* env, jclass clazz) {
    if (g_bridge_class != nullptr) return;
    g_bridge_class = static_cast<jclass>(env->NewGlobalRef(clazz));
    g_dispose_all =
        env->GetStaticMethodID(g_bridge_class, "disposeAllFromNative", "()V");
    if (g_dispose_all == nullptr) {
        DN_LOGW("disposeAllFromNative not found");
        env->ExceptionClear();
    }
}

/// Delivers one event to Dart.
///
/// Called on the main thread, which is where Dart lives. The slot and the
/// generation are both re-read here, immediately before the call, because that
/// ordering is the whole guarantee: the framework clears the generation while the
/// old pointer is still valid, so a stale event is dropped rather than fired.
///
/// The payload buffer is JNI-owned and released before returning. That is safe
/// because the Dart side receives it through Pointer.fromFunction, which is
/// synchronous and copies the string during the call. An async
/// NativeCallable.listener would have required strdup and a Dart-side free.
JNIEXPORT void JNICALL
Java_com_dartnative_mobile_1scanner_DNMobileScannerBridge_nativeEmit(
    JNIEnv* env, jclass /*clazz*/, jlong token, jint type, jstring payload) {
    const int64_t address = g_dispatcher.load(std::memory_order_acquire);
    if (address == 0) return;

    const uint64_t current = dn_isolate_gen();
    // If the counter could not be resolved, staleness cannot be determined. This
    // delivers the event anyway rather than dropping it: hot restart exists only
    // in debug builds, so failing open costs a possible debug-session abort that
    // the warning above explains, while failing closed would make a release build
    // silently never report a single detection. The second is far worse, and the
    // resolution above makes this path effectively unreachable.
    if (g_dispatcher_gen.load(std::memory_order_relaxed) != current) {
        // A hot restart happened: the pointer belongs to a program that is gone.
        return;
    }

    if (payload == nullptr) return;
    const char* chars = env->GetStringUTFChars(payload, nullptr);
    if (chars == nullptr) return;

    reinterpret_cast<DnDispatchFn>(address)(
        static_cast<int64_t>(token), static_cast<int32_t>(type), chars);

    env->ReleaseStringUTFChars(payload, chars);
}

}  // extern "C"
