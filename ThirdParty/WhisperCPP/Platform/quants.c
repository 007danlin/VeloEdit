#if defined(__x86_64__)
#include "../ggml/src/ggml-cpu/arch/x86/quants.c"
#elif defined(__aarch64__)
#include "../ggml/src/ggml-cpu/arch/arm/quants.c"
#else
#error Unsupported CPU architecture
#endif
