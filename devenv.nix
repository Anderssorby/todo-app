{ pkgs, ... }:

{
  # Mirrors ../monad/devenv.nix's native-build toolchain: `monad build`
  # shells out to llc (codegen) and lld/clang (linking), and the generated
  # runtime links against -lgc (Boehm GC) via clang's search path.
  packages = with pkgs; [
    llvm # llc
    lld
    clang
    boehmgc
  ];
}
