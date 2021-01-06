# Cross Platform Rust

This greetings example is an example of a rust core `#![no_std]` crate that uses a global allocator that is platform dependent. There is an allocator init function, then a function to perform some action and return the result as a pointer to a Rust-allocated buffer, then a function to free that buffer. This was tested running on an iPhone (aarch64) and an nrf52832 development kit (ARM Cortex M4).

## Compiling for iOS

Since this was the result of investigation there might be some missing steps or steps that change over time. For example, some guides may reference 32-bit apple targets, which have dropped to tier 3 support in the Rust community after Apple dropped support.

1. `rustup toolchain install nightly` or `rustup update nightly`
1. `cargo install cargo-lipo`
1. `rustup +nightly target add apple-arch64-ios apple-x86_64-ios`
1. `cargo +nightly lipo --release`

This will install
* the apple universal library archiver lipo
* the nightly toolchain, some features may or may not be supported on stable but nightly is pretty consistent for rust
* the cross platform targets for ios for the nightly version installed by rustup

Then we build the universal library at `target/universal/release/lib_greetings_rs.a`:
```
jwtrueb@jbmp cargo % cargo +nightly lipo --release
[INFO  cargo_lipo::meta] Will build universal library for ["greetings_rs"]
[INFO  cargo_lipo::lipo] Building "greetings_rs" for "aarch64-apple-ios"
   Compiling typenum v1.12.0
   Compiling version_check v0.9.2
   Compiling fs_extra v1.2.0
   Compiling byteorder v1.3.4
   Compiling cc v1.0.62
   Compiling libc v0.2.80
   Compiling memchr v2.3.4
   Compiling heapless v0.5.6
   Compiling stable_deref_trait v1.2.0
   Compiling cty v0.2.1
   Compiling generic-array v0.14.4
   Compiling jemalloc-sys v0.3.2
   Compiling cstr_core v0.2.2
   Compiling hash32 v0.1.1
   Compiling generic-array v0.12.3
   Compiling generic-array v0.13.2
   Compiling as-slice v0.1.4
   Compiling jemallocator v0.3.2
   Compiling greetings_rs v0.1.0 (/Users/jwtrueb/Desktop/workspace/qsib-sensor/qsib-sensor-prot/cargo)
    Finished release [optimized] target(s) in 25.19s
[INFO  cargo_lipo::lipo] Building "greetings_rs" for "x86_64-apple-ios"
   Compiling stable_deref_trait v1.2.0
   Compiling cty v0.2.1
   Compiling typenum v1.12.0
   Compiling libc v0.2.80
   Compiling byteorder v1.3.4
   Compiling memchr v2.3.4
   Compiling heapless v0.5.6
   Compiling generic-array v0.14.4
   Compiling jemalloc-sys v0.3.2
   Compiling hash32 v0.1.1
   Compiling cstr_core v0.2.2
   Compiling generic-array v0.12.3
   Compiling generic-array v0.13.2
   Compiling as-slice v0.1.4
   Compiling jemallocator v0.3.2
   Compiling greetings_rs v0.1.0 (/Users/jwtrueb/Desktop/workspace/qsib-sensor/qsib-sensor-prot/cargo)
    Finished release [optimized] target(s) in 20.57s
[INFO  cargo_lipo::lipo] Creating universal library for greetings_rs
jwtrueb@jbmp cargo % ls -ltrh target/universal/release/libgreetings_rs.a
-rw-r--r--  1 jwtrueb  staff    22M Nov 18 09:52 target/universal/release/libgreetings_rs.a
```

## Compiling for ARM Cortex M4

We don't have to actually target just the M4, check out the comments in .cargo/config for the configs related the embedded rust options for other ARM targets. The embedded community for rust has a lot going on, but a lot of the options are targetted towards running an embedded OS rather than creating a staticlib to link into an embedded OS. The introduction at https://rust-embedded.github.io/book/ can lead you down the right paths to start investigating questions that you might have.

There isn't much to do to get ARM Cortex M4 going since it is a staticlib built off of the core of Rust (libcore). Using the nightly is currently required to enable lang_items and default alloc error handling.
1. `rustup toolchain install nightly` or `rustup update nightly`
1. `cargo +nightly build --release`

Notice that the cortex_m_rt is used to run a CortexMHeap as the global allocator instead of the standard jemallocator.

```
jwtrueb@jbmp cargo % cargo +nightly build --release
   Compiling typenum v1.12.0
   Compiling version_check v0.9.2
   Compiling semver-parser v0.7.0
   Compiling proc-macro2 v1.0.24
   Compiling stable_deref_trait v1.2.0
   Compiling unicode-xid v0.2.1
   Compiling byteorder v1.3.4
   Compiling syn v1.0.48
   Compiling vcell v0.1.2
   Compiling cortex-m v0.6.4
   Compiling memchr v2.3.4
   Compiling bitfield v0.13.2
   Compiling cortex-m-rt v0.6.13
   Compiling heapless v0.5.6
   Compiling cty v0.2.1
   Compiling linked_list_allocator v0.8.6
   Compiling r0 v0.2.2
   Compiling volatile-register v0.2.0
   Compiling semver v0.9.0
   Compiling generic-array v0.14.4
   Compiling rustc_version v0.2.3
   Compiling bare-metal v0.2.5
   Compiling hash32 v0.1.1
   Compiling cstr_core v0.2.2
   Compiling quote v1.0.7
   Compiling generic-array v0.13.2
   Compiling generic-array v0.12.3
   Compiling as-slice v0.1.4
   Compiling aligned v0.3.4
   Compiling alloc-cortex-m v0.4.0
   Compiling cortex-m-rt-macros v0.1.8
   Compiling greetings_rs v0.1.0 (/Users/jwtrueb/Desktop/workspace/qsib-sensor/qsib-sensor-prot/cargo)
    Finished release [optimized] target(s) in 11.15s
jwtrueb@jbmp cargo % ls -ltrh target/thumbv7em-none-eabi/release/libgreetings_rs.a
-rw-r--r--  2 jwtrueb  staff   5.5M Nov 18 10:06 target/thumbv7em-none-eabi/release/libgreetings_rs.a
```

## Usage in Xcode


1. Add libresolv.tdb as an embedded library
1. Add the library as an embedded library
1. Add the greetings.h header from this project
1. Add a bridging header that includes greetings.h
1. Configure the bridging header as _the_ bridging header in Swift Compiler General settings
1. Configure the Library Search Paths option value to `$(PROJECT_DIR)/../../qsib-sensor-lib-rs/target/universal/release` (place adjacent repos accordingly)
1. Add a wrapper facade
```swift
import Foundation

class RustGreetings {
    static let initializer: Void = {
        rust_init();
        return ()
    }()

    func sayHello(to: String) -> String {
        let result = rust_greeting(to)
        let swift_result = String(cString: result!)
        rust_greeting_free(UnsafeMutablePointer(mutating: result))
        return swift_result
    }
}
```

## Usage with Zephyr

1. Copy the archive and header into a folder in the source dir like `src/lib`
2. Add the library in CMakeList.txt
```
add_library(mylib_lib STATIC IMPORTED GLOBAL)
set_target_properties(mylib_lib PROPERTIES IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/lib/libgreetings_rs.a)
target_link_libraries(app PUBLIC mylib_lib)
```
3. Add a linker script to add the Cortex M Heap in RAM, shown as `src/sheap-rs.ld`
```linker
SECTION_PROLOGUE(.sheap,,ALIGN(4))
{
    __sheap = .;
} GROUP_LINK_IN(RAMABLE_REGION)
```
4. Configure the linker script to work with the Zephyr build system in CMakeList.txt
```
zephyr_linker_sources(RAM_SECTIONS ${CMAKE_CURRENT_SOURCE_DIR}/src/sheap-rs.ld)
target_link_options(app PUBLIC "-Wl,--allow-multiple-definition")
```
5. Include the `greetings.h` in `main.cpp` and use the interface:
```
// Include greetings as C, may need extern "C" for C++
rust_init();
char* greeting = rust_greeting("Zephyr");
LOG_INF("Rust says '%s'", log_strdup(greeting));
rust_greeting_free(greeting);
```

## Usage in Tests

During test configs, we allow usage of std for ease of use. This shoudl not impact the actual functionality of the library. The following is an example of compiling for macos and running tests locally.

```
jwtrueb@jbmp cargo % cargo +nightly test --target x86_64-apple-darwin -- --nocapture
   Compiling greetings_rs v0.1.0 (/Users/jwtrueb/Desktop/workspace/qsib-sensor/qsib-sensor-prot/cargo)
    Finished test [unoptimized + debuginfo] target(s) in 1.23s
     Running target/x86_64-apple-darwin/debug/deps/greetings_rs-47a492705e47a9a1

running 1 test
Rust Test says "Hello World"
test tests::say_hello ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
```