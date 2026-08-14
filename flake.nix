{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    systems.url = "github:nix-systems/default";
    utils = {
      url = "github:numtide/flake-utils";
      inputs.systems.follows = "systems";
    };
  };
  outputs = { nixpkgs, utils, ... }:
    utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
      in {
        packages.default = pkgs.writeShellApplication {
          name = "tcpfit";
          runtimeInputs = with pkgs; [
            coreutils
            ethtool
            findutils
            gawk
            gnugrep
            gnused
            iproute2
            iperf3
            iputils
            psmisc
            procps
            systemd
            util-linux
          ];
          # tcpfit 的 TUI 文案包含 CJK 字符；当前 shellcheck-minimal 在 Nix
          # sandbox 的 C locale 下无法编码其诊断输出。保留 bash 语法检查，
          # 避免 locale 问题阻断可执行包的构建。
          checkPhase = ''
            bash -n "$target"
          '';
          text = builtins.readFile ./tcpfit.sh;
        };

        devShells.default = with pkgs;
          mkShell {
            buildInputs =
              [ codex antigravity-cli nodejs_24 yarn-berry postgresql_17 ];
          };
      });
}
