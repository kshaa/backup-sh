{ sources ? import ./nix/sources.nix }: 
let
    pkgs = import sources.nixpkgs {};
    backup-sh = import ./. {};
in pkgs.mkShell {
    buildInputs = [
        backup-sh
    ];
}
