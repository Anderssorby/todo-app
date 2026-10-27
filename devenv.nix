{ pkgs, ... }:

let
  # wasi-sdk 34.0 is pinned from the official release tarball, mirroring
  # ../monad/nix/packages.nix: it is not packaged in the pinned nixpkgs.
  # `monad build --target wasm32-…` selects it through $WASI_SDK_PATH by
  # absolute path, so its `bin/clang` must stay off PATH -- putting it
  # there would shadow the native clang and default every build to wasm32.
  wasiSdk = pkgs.stdenv.mkDerivation rec {
    pname = "wasi-sdk";
    version = "34.0";

    src = pkgs.fetchurl {
      url = "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-34/wasi-sdk-${version}-x86_64-linux.tar.gz";
      sha256 = "sha256-t2HjoHIduunAmgBZ5f2yv5F9G0qKe0MPs7Wq+wmEssQ=";
    };

    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = [
      pkgs.ncurses
      pkgs.zlib
      pkgs.stdenv.cc.cc.lib
    ];

    sourceRoot = "wasi-sdk-${version}-x86_64-linux";
    dontStrip = true;

    installPhase = ''
      mkdir -p $out
      cp -r . $out/
    '';

    meta.platforms = [ "x86_64-linux" ];
  };
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
    # $WASI_SDK_PATH (see above).
    wasmtime
    nodejs
  ];

  # The pinned wasi-sdk tarball is the x86_64-linux release. On any other
  # host the binding is empty and `--target wasm32-…` fails with the
  # compiler's clear WASI_SDK_PATH diagnostic instead.
  env.WASI_SDK_PATH =
    if pkgs.stdenv.hostPlatform.system == "x86_64-linux" then "${wasiSdk}" else "";
}
