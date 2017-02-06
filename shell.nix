with import <nixpkgs> { };

haskell.lib.buildStackProject {
   name = "node-sketch";
   ghc = haskell.packages.ghc802.ghc;
   buildInputs = [
     openssh autoreconfHook git 
   ] ++ (lib.optionals stdenv.isLinux [ cabal-install stack ]);
   LANG = "en_US.UTF-8";
}
