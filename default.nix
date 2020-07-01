{ sources ? import ./nix/sources.nix }: 
let
    pkgs = import sources.nixpkgs {};
    gitignore = import sources.gitignore {};
    gitignoreSource = gitignore.gitignoreSource;
in with pkgs; stdenv.mkDerivation {
    pname = "backup-sh";
    version = "1.0.0";
    nativeBuildInputs = [ makeWrapper ];
    src = gitignoreSource ./.;
    installPhase = ''
        install -m755 -D backup.sh "$out/bin/backup.sh"
        wrapProgram "$out/bin/backup.sh" \
            --prefix PATH : "${stdenv.lib.makeBinPath [ acl yq jq rsync mktemp openssh sshpass ]}"
    '';
}