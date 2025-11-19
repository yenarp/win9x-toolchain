# Win95 Toolchain

This project aims to provide a simple to use, linux native toolchain to develop and compile software targeting Windows 9x, primarily Windows 95 OSR2.
Templates use i686-w64-mingw32 with custom dll bindings to prevent the linker from injecting API sets (targetted at OSR2), alongside a script to generate your own bindings for a specific machine in case of a mismatch.

# TODO
- [ ] Separate DLL bindings for specific releases of win95
    - [ ] Add support for win98 and ME
