
{ pkgs, ... }:
{
	# https://github.com/nix-community/nixvim/tree/main
	programs.nixvim = {
		enable = true;
		#     defaultEditor = true;

		colorschemes.gruvbox.enable = true;
		opts = {
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
			# {
			# 	key = "<leader><Tab>";
			# 	action = "<cmd>NvimTreeFocus<CR>";
			# }
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
			{
				key = "f";
				action.__raw = ''
			function()
				require'hop'.hint_char1({
					direction = require'hop.hint'.HintDirection.AFTER_CURSOR,
					-- current_line_only = true
				})
			end
			'';
				options.remap = true;
			}
			{
				key = "F";
				action.__raw = ''
			function()
				require'hop'.hint_char1({
					direction = require'hop.hint'.HintDirection.BEFORE_CURSOR,
					-- current_line_only = true
				})
			end
			'';
				options.remap = true;
			}
			{
				key = "t";
				action.__raw = ''
			function()
				require'hop'.hint_char1({
					direction = require'hop.hint'.HintDirection.AFTER_CURSOR,
					-- current_line_only = true,
					hint_offset = -1
				})
			end
			'';
				options.remap = true;
			}
			{
				key = "T";
				action.__raw = ''
			function()
				require'hop'.hint_char1({
					direction = require'hop.hint'.HintDirection.BEFORE_CURSOR,
					-- current_line_only = true,
					hint_offset = 1
				})
			end
			'';
				options.remap = true;
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

					vim.g.clipboard = {
						name = 'OSC 52',
						copy = {
							['+'] = require('vim.ui.clipboard.osc52').copy('+'),
							['*'] = require('vim.ui.clipboard.osc52').copy('*'),
						},
						paste = {
							['+'] = require('vim.ui.clipboard.osc52').paste('+'),
							['*'] = require('vim.ui.clipboard.osc52').paste('*'),
						},
					}
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

			hop = {
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
						"ga" = "code_action";
					};
				};
				servers = {
					nil-ls = {
						enable = true;
						settings = {
							nix = {
								flake = {
									autoArchive = true;
								};
							};
						};
					};
					# rust-analyzer = {
					#         enable = true;
					#         installCargo = true;
					#         installRustc = true;
					# };
					bashls.enable = true;
					ruff-lsp.enable = true;
					pylsp.enable = true;
				};
			};
			coq-nvim = {
				enable = true;
				settings = {
					auto_start = true;
					completion = {
						always = true;
					};
					installArtifacts = true;
					keymap = {
						recommended = false;
					};
				};
			};
			notify.enable = true;

			rustaceanvim = {
				enable = true;
			};

			web-devicons.enable = true;

			auto-session.enable = true;

			intellitab.enable = true;
			comment.enable = true;
			persistence.enable = true;
			floaterm.enable = true;
			goyo.enable = true;
			noice.enable = true;
			which-key.enable = true;
			neogit.enable = true;
			diffview.enable = true;
			# nvim-tree = {
			# 	enable = true;
			# 	openOnSetup = true;
			# };
			treesitter.enable = true;
			telescope = {
				enable = true;
				extensions = {
					fzf-native.enable = true;
					ui-select.enable = true;
					file-browser.enable = true;
				};
				keymaps = {
					"<leader>ff" = "find_files";
					"<leader>fg" = "live_grep";
					"<leader>fb" = "buffers";
					"<leader>fh" = "help_tags";
					"<leader>fr" = "oldfiles";
					"<leader>ft" = "tags";
					"<leader>fs" = "lsp_document_symbols";
					"<leader>fw" = "lsp_workspace_symbols";
					"<leader>fp" = "lsp_references";
					"<leader>fl" = "lsp_definitions";
					"<leader>f." = "file_browser path=%:p:h select_buffer=true";
					"<leader>fa" = "file_browser";
				};
				settings = {
					defaults = {
						layout_strategy = "vertical";
						layout_config = {
							width = 100;
							height = 0.7;
							anchor = "SE";
						};
					};
				};
			};
			
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

			conform-nvim.settings = {
				format_on_save = {
					lspFallback = true;
					timeoutMs = 500;
				};
			};
			direnv.enable = true;
		};

	};
}
