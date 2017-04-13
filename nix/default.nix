{ pkgs ? import <nixpkgs> {} }:

let
super = pkgs;
self = {
  hsl = super.callPackage ./hsl.nix {};
  ipopt = super.callPackage ./ipopt.nix { inherit (self) hsl; };
  casadi = super.callPackage ./casadi.nix { inherit (self) ipopt hsl; };
};
in self
