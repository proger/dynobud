let
  # this only builds on darwin if you use --no-system-ghc (needs patching stack to allow it)
  pkgs = import <nixpkgs> {};
  inherit (pkgs) lib stdenv;
  extra = import ./nix { inherit pkgs; };
  inputs = (with pkgs; [
    gtk3
    zlib
    pkgconfig
    libcxx
    openblas
    gsl_1
    zeromq4
    gfortran.cc.out
  ]) ++ (with extra; [
    casadi
  ]);
  libPath = lib.makeLibraryPath inputs;
  stackExtraArgs = lib.concatMap (pkg: [
    ''--extra-lib-dirs=${lib.getLib pkg}/lib''
    ''--extra-include-dirs=${lib.getDev pkg}/include''
  ]) inputs;
in
pkgs.runCommand "myEnv" {
  buildInputs = lib.optional stdenv.isLinux pkgs.glibcLocales ++ inputs;
  STACK_PLATFORM_VARIANT = "nix";
  STACK_IN_NIXSHELL = 1;
  LD_LIBRARY_PATH = libPath;
  DYLD_LIBRARY_PATH = libPath;
  STACK_IN_NIX_EXTRA_ARGS = stackExtraArgs;
} ""
