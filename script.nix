{
  pkgs,
  lib,
}: {
  name,
  shell ? pkgs.bash,
  text,
  runtimeInputs ? [],
  ...
}: let
  mainProgram = shell.meta.mainProgram or shell.pname;
  shellBin = "${shell}/bin/${mainProgram}";

  raw = pkgs.writeTextFile {
    name = "${name}-script";
    executable = true;
    destination = "/bin/${name}";
    text = ''
      #!${shellBin}
      ${text}
    '';
  };
in
  if runtimeInputs == []
  then raw
  else
    pkgs.symlinkJoin {
      inherit name;
      paths = [raw];
      buildInputs = [pkgs.makeWrapper];
      postBuild = ''
        wrapProgram $out/bin/${name} \
          --prefix PATH : ${lib.makeBinPath runtimeInputs}
      '';
    }
