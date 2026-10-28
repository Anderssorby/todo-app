{ pkgs, ... }:

let
  wasiSdk = import ./nix/wasi-sdk.nix { inherit pkgs; };
in
{
  # Mirrors ../monad/devenv.nix's native-build toolchain: `monad build`
  # shells out to llc (codegen) and lld/clang (linking), and the generated
  # runtime links against -lgc (Boehm GC) via clang's search path.
  packages = with pkgs; [
    llvm # llc
    lld
    clang
    # `monad build` links the generated runtime with `-Wl,-Bstatic -lgc`,
    # so the dev shell must ship `libgc.a` alongside `libgc.so` (the same
    # override ../monad/nix/packages.nix carries). Without `enableStatic`
    # the link fails with "cannot find -lgc" / "have you installed the
    # static version of the gc library?".
    (boehmgc.override { enableStatic = true; })
    # WASM (M5+): wasmtime runs the wasi profile; node runs the web
    # profile's smoke harness. wasi-sdk itself is reachable only through
    # $WASI_SDK_PATH (see nix/wasi-sdk.nix).
    wasmtime
    nodejs
  ];

  # The pinned wasi-sdk tarball is the x86_64-linux release. On any other
  # host the binding is empty and `--target wasm32-…` fails with the
  # compiler's clear WASI_SDK_PATH diagnostic instead.
  env.WASI_SDK_PATH =
    if pkgs.stdenv.hostPlatform.system == "x86_64-linux" then "${wasiSdk}" else "";
}
