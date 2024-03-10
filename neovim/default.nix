
{ ... }:
{
    # https://github.com/nix-community/nixvim/tree/main
    programs.nixvim = {
            enable = true;
        #     defaultEditor = true;

            colorschemes.gruvbox.enable = true;
            options = {
                    number = true;
                    relativenumber = true;
                    tabstop = 4;
                    shiftwidth = 4;
                    smartindent = true;
            };

            keymaps = [
				{
                    key = " ";
                    mode = "n";
                    action = "<Nop>";
            	}
				{
					key = "<leader><Tab>";
					action = "<cmd>NvimTreeFocus<CR>";
				}
			];

            extraConfigLua = ''
                    vim.keymap.set("i", '<Tab>', function()
                        if require("copilot.suggestion").is_visible() then
                        require("copilot.suggestion").accept()
                        else
                        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "n", false)
                        end
                        end, {
                        silent = true,
                    })
            '';


            globals.mapleader = " ";

            plugins = {
                    lightline.enable = true;
                    lsp = {
                            enable = true;
                            servers = {
                                    nil_ls.enable = true;
                                    rust-analyzer = {
                                            enable = true;
                                            installCargo = true;
                                            installRustc = true;
                                    };
                                    bashls.enable = true;
                                    ruff-lsp.enable = true;
                            };
                    };
                    coq-nvim = {
                            enable = true;
                            autoStart = true;
                            alwaysComplete = true;
                            installArtifacts = true;
                    };
                    coq-thirdparty = {
                        sources = [{
                            acceptKey = "<TAB>";
                            short_name = "COP";
                            src = "copilot";
                        }];
                    };
                    persistence.enable = true;
                    floaterm.enable = true;
                    goyo.enable = true;
                    noice.enable = true;
                    which-key.enable = true;
                    neogit.enable = true;
                    nvim-tree = {
                        enable = true;
                        openOnSetup = true;
                    };
                    telescope.enable = true;
                    #dashboard.enable = true;
                    #copilot-vim.enable = true;
                    copilot-lua = {
                        enable = true;
                        suggestion = {
                            autoTrigger = true;
                            keymap = {
                                accept = "<C-i>";
                            };
                        };	
                    };
                    conform-nvim = {
                            formatOnSave = {
                                    lspFallback = true;
                                    timeoutMs = 500;
                            };
                    };
            };

		};
}
