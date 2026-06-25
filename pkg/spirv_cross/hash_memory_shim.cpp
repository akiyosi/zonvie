// Weak definition of std::__1::__hash_memory for the macOS Xcode link.
//
// Zig 0.16 bundles libc++ 21, whose std::hash for memory blocks calls the
// out-of-line ABI symbol std::__1::__hash_memory (gated by
// _LIBCPP_AVAILABILITY_HAS_HASH_MEMORY == _LIBCPP_INTRODUCED_IN_LLVM_21, which
// is treated as always-available on the vendored toolchain). The glslang C++
// objects reference it.
//
// On Zig-linked outputs (the Windows build, `zig build test`/`e2e`) the symbol
// is provided by Zig's own libc++, so nothing is missing. But the macOS app is
// linked by Xcode against Apple's SYSTEM libc++, which is older and does not
// export __hash_memory yet — the link fails with an undefined symbol.
//
// Provide a WEAK definition (identical body to libc++'s own inline fallback)
// so the Xcode link resolves it. On Zig-linked paths the real strong
// definition wins and this weak one is discarded, so there is no duplicate
// symbol. spirv_cross is compiled with libc++ and merged into libzonvie_core
// for the macOS app, which is why the shim lives here.

#include <__functional/hash.h>
#include <cstddef>

_LIBCPP_BEGIN_NAMESPACE_STD

// Signature matches the libc++ declaration exactly (pure attribute, _NOEXCEPT
// exception spec, _LIBCPP_NOESCAPE param) so it is the same function type and
// mangles to the referenced symbol; `weak` lets the real libc++ definition win
// on Zig-linked outputs without a duplicate-symbol error.
[[__gnu__::__pure__]] __attribute__((weak)) size_t
__hash_memory(_LIBCPP_NOESCAPE const void* __ptr, size_t __size) _NOEXCEPT {
  return __murmur2_or_cityhash<size_t>()(__ptr, __size);
}

_LIBCPP_END_NAMESPACE_STD
