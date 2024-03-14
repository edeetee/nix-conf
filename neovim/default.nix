
{ pkgs, ... }:
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
					scrolloff = 6;
            };

			

            keymaps = [
				{
                    key = " ";
                    action = "<Nop>";
            	}
				{
					key = "<leader><Tab>";
					action = "<cmd>NvimTreeFocus<CR>";
				}
				{
					key = "<leader>g";
					action = "<cmd>Neogit<CR>";
				}
				{
					key = "<leader>tf";
					action = "<cmd>FloatermToggle<CR>";
				}
				{
					key = "<leader>t";
					action = "<cmd>terminal<CR>";
				}
				{
					key = "<Esc>";
					action = ''<C-\><C-n>'';
					mode = "t";
				}
			];


			extraConfigVim = ''
				" 🐓 Coq completion settings

				" Set recommended to false
				let g:coq_settings = { "keymap.recommended": v:false }

			" Keybindings
				ino <silent><expr> <Esc>   pumvisible() ? "\<C-e><Esc>" : "\<Esc>"
				ino <silent><expr> <C-c>   pumvisible() ? "\<C-e><C-c>" : "\<C-c>"
				ino <silent><expr> <BS>    pumvisible() ? "\<C-e><BS>"  : "\<BS>"
				ino <silent><expr> <CR>    pumvisible() ? (complete_info().selected == -1 ? "\<C-e><CR>" : "\<C-y>") : "\<CR>"
				ino <silent><expr> <S-Tab> pumvisible() ? "\<C-p>" : "\<BS>"
			'';


			# https://github.com/zbirenbaum/copilot.lua/issues/91#issuecomment-1345190310

            extraConfigLua = ''
                    vim.keymap.set("i", '<Tab>', function()
                        if require("copilot.suggestion").is_visible() then
                        	require("copilot.suggestion").accept()
                        else
							if vim.fn.pumvisible() == 1 then
								--return '<C-n>'
								vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-n>', true, false, true), "n", false)
							else
								require("intellitab").indent()
							end
							--new_key = vim.fn.pumvisible() == 1 and '<c-n>' or '<tab>'
                        	--return new_key
							--vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(new_key, true, false, true), "n", false)
                        end
                    end, {
                        silent = true,
                    })
            '';

			extraPlugins = with pkgs.vimPlugins; [
				# supertab
			];

            globals.mapleader = " ";

            plugins = {
                    lightline.enable = true;

					dap = {
						enable = true;
					};

                    lsp = {
                            enable = true;
							keymaps = {
								diagnostic = {
									"<leader>k" = "goto_prev";
									"<leader>j" = "goto_next";
								};
								lspBuf = {
									"gd" = "definition";
									"gD" = "references";
									"gt" = "type_definition";
									"gi" = "implementation";
									"K" = "hover";
								};
							};
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
							recommendedKeymaps = false;
                    };

                    # coq-thirdparty = {
                    #    sources = [{
                    #        accept_key = "<Tab>";
                    #        short_name = "COP";
                    #        src = "copilot";
                    #    }];
                    # };
					intellitab.enable = true;
					comment-nvim.enable = true;
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
					treesitter.enable = true;
                    telescope.enable = true;
                    #dashboard.enable = true;
                    #copilot-vim.enable = true;
                    copilot-lua = {
                        enable = true;
                        suggestion = {
                            autoTrigger = true;
                            keymap = {
                                accept = false;
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
