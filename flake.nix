{
  description = "Code review inside Neovim";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      # Shared by `packages` and the overlay so both build the same derivation.
      mkRemarkNvim =
        pkgs:
        pkgs.vimUtils.buildVimPlugin {
          pname = "remark.nvim";
          version = self.shortRev or self.dirtyShortRev or "dev";
          src = self;

          meta = {
            description = "Code review, without leaving neovim.";
            homepage = "https://github.com/sebnow/remark.nvim";
            platforms = systems;
          };
        };
    in
    {
      overlays.default = final: prev: {
        vimPlugins = prev.vimPlugins // {
          remark-nvim = mkRemarkNvim final;
        };
      };

      packages = forAllSystems (pkgs: rec {
        default = remark-nvim;

        remark-nvim = mkRemarkNvim pkgs;
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.neovim
            pkgs.lua-language-server
            pkgs.stylua
            pkgs.luajit
            pkgs.jujutsu
            pkgs.git
            pkgs.vimPlugins.mini-nvim
          ];

          # tests/minimal_init.lua adds mini.test to the runtimepath from this path (ADR 0007).
          MINI_NVIM_RTP = "${pkgs.vimPlugins.mini-nvim}";

          shellHook = ''
            echo "remark.nvim dev shell"
            echo "  nvim -u scripts/minimal_init.lua   # run the plugin in a scratch session"
            echo "  scripts/test.sh                    # run the test suite"
          '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
    };
}
