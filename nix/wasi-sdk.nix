# wasi-sdk 34.0 is pinned from the official release tarball, mirroring
# ../monad/nix/packages.nix: it is not packaged in the pinned nixpkgs.
# `monad build --target wasm32-…` selects it through $WASI_SDK_PATH by
# absolute path, so its `bin/clang` must stay off PATH -- putting it there
# would shadow the native clang and default every build to wasm32.
{ pkgs }:
pkgs.stdenv.mkDerivation rec {
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
}
