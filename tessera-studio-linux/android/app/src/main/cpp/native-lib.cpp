#include <jni.h>
#include <string>
// Minimal JNI bridge to shared C++ core (mirrors ffi/tessera_ffi.cpp)
// Real link: include tessera-studio-linux/src/core/provider.h etc and call make_provider_on_device
extern "C" JNIEXPORT jstring JNICALL
Java_org_tessera_MainActivity_nativeInit(JNIEnv* env, jobject) {
    return env->NewStringUTF("tessera core init — shared C++ via JNI");
}
extern "C" JNIEXPORT jstring JNICALL
Java_org_tessera_MainActivity_nativeChat(JNIEnv* env, jobject, jstring prompt) {
    const char* c = env->GetStringUTFChars(prompt, nullptr);
    std::string p = c ? c : "";
    if(c) env->ReleaseStringUTFChars(prompt, c);
    // Fallback echo; real would dlopen libllama.so from app's nativeLibDir
    std::string r = "[android] echo: " + p;
    return env->NewStringUTF(r.c_str());
}
