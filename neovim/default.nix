
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
			title = true;
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
				key = "<leader>w";
				action = "<cmd>write<CR>";
			}
			{
				key = "<leader>q";
				action = "<cmd>quitall<CR>";
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
			{
				key = "<Right>";
				mode = ["i"];
				action.__raw = ''
			function()
				require("copilot.suggestion").accept()
			end
			'';
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

				" Keybindings
				ino <silent><expr> <Esc>   pumvisible() ? "\<C-e><Esc>" : "\<Esc>"
				ino <silent><expr> <C-c>   pumvisible() ? "\<C-e><C-c>" : "\<C-c>"
				ino <silent><expr> <BS>    pumvisible() ? "\<C-e><BS>"  : "\<BS>"
				ino <silent><expr> <CR>    pumvisible() ? (complete_info().selected == -1 ? "\<C-e><CR>" : "\<C-y>") : "\<CR>"
				ino <silent><expr> <S-Tab> pumvisible() ? "\<C-p>" : "\<BS>"
				'';


		# https://github.com/zbirenbaum/copilot.lua/issues/91#issuecomment-1345190310

		extraConfigLua = ''
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
					nil_ls = {
						enable = true;
						settings = {
							nix = {
								flake = {
									autoArchive = true;
								};
							};
						};
					};
					rust_analyzer = {
					        enable = true;
					        installCargo = true;
					        installRustc = true;
					};
					bashls.enable = true;
					# ruff_lsp.enable = true;
					pylsp.enable = true;
					dartls.enable = true;
				};
			};
			# coq-nvim = {
			# 	enable = true;
			# 	settings = {
			# 		auto_start = "shut-up";
			# 		# installArtifacts = true;
			# 		keymap = {
			# 			recommended = false;
			# 		};
			# 	};
			# };

			cmp = {
				enable = true;
				autoEnableSources = true;
				settings = {
					mapping = {
						"<C-d>" = "cmp.mapping.scroll_docs(-4)";
						"<C-f>" = "cmp.mapping.scroll_docs(4)";
						"<C-Space>" = "cmp.mapping.complete()";
						"<C-e>" = "cmp.mapping.close()";
					# 	"<Tab>" = "cmp.mapping(cmp.mapping.select_next_item(), {'i', 's'})";
						"<S-Tab>" = "cmp.mapping(cmp.mapping.select_prev_item(), {'i', 's'})";
						# "<CR>" = "cmp.mapping.confirm({ select = true })";
						"<Tab>" = ''
		  cmp.mapping(
			function(fallback)
			  if cmp.visible() then
				cmp.select_next_item()
			  elseif require("copilot.suggestion").is_visible() then
				require("copilot.suggestion").accept()
			  else
				require("intellitab").indent()
			  end
			end,
			{ "i", "s" }
		  )
						'';
					};
					sources = [
						{ name = "nvim_lsp"; }
						{ name = "path"; }
						{ name = "buffer"; }
						{ name = "copilot"; }
					];
				};
			};


			notify.enable = true;

			# rustaceanvim.enable = true;

			web-devicons.enable = true;

			auto-session.enable = true;
			
			vim-surround.enable = true;
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
				# settings = {
					suggestion.enabled = false;
					panel.enabled = false;
					# copilot_node_command = "${pkgs.nodejs_24}/bin/node";
					# node_command = "${pkgs.nodejs_24}/bin/node";
				# };
				# suggestion = {
				# 	enabled = true;
				# 	autoTrigger = true;
				# 	keymap = {
				# 		accept = false;
				# 	};
				# };	
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
