{ pkgs ? import <nixpkgs> {} # here we import the nixpkgs package set   
}:                                                                      
pkgs.mkShell {               # mkShell is a helper function             
  name="dev-environment";    # that requires a name                     
  buildInputs = [            # and a list of packages                   
    # pkgs.cabal-install
    # pkgs.ghc
  ];                                                                    
}
