# 📘 `ipynb.nvim`

A modal Jupyter notebook editor for Neovim that reads and writes `.ipynb` files
exactly like Jupyter, so the same notebook works in JupyterLab, Google Colab,
Databricks, VS Code and here.

> [!NOTE]
> This is a fork of [ajbucci/ipynb.nvim](https://github.com/ajbucci/ipynb.nvim) that fixes data loss and
> Windows bugs and adds the notebook features listed below. It is still young: back up notebooks you care about.

<img width="752" height="517" alt="Screenshot From 2026-01-17 01-28-38" src="https://github.com/user-attachments/assets/6784bcce-ab98-4f5a-9383-567e252276bc" />

## ✨ Features

- **Notebook files, Jupyter-exact**: saving an untouched notebook changes nothing (same key order, indent and
  line splitting as `nbformat`, CRLF kept); attachments, tags, Colab/Kaggle/Databricks metadata and unknown
  output types are preserved; saved files pass `nbformat.validate`
- **Cells**: code / markdown / raw; add, cut, copy, paste, move, merge, split; undo across cells; tags and
  titles (Databricks titles, Colab `#@title`) on the cell border; hide code / hide outputs saved like JupyterLab
- **Editing**: each cell in its own buffer with your keymaps and LSP, either *overlaid on the cell* or in a
  **split next to the notebook** so earlier cells and outputs stay in view while you type
- **Running**: run cell / and next / and insert, run all, above, below, selection; restart and run all;
  interrupt; `input()` prompts; queued vs running state and run time per cell; stops after an error like Jupyter
- **Any Jupyter kernel**: Python, R, Julia, Go, Rust, … on this machine, **on a Jupyter server** (JupyterLab,
  JupyterHub, `jupyter server`), or via a connection file; cells run in an [iron.nvim](https://github.com/Vigemus/iron.nvim)
  REPL when a language has no kernel
- **Outputs**: streams with progress bars, coloured tracebacks (ANSI), `clear_output` and display updates,
  readable HTML/Markdown/LaTeX/JSON fallbacks (tables become aligned text), long outputs truncated with a note
- **Images**: inline via kitty (snacks.nvim), **Sixel** (Windows Terminal, foot, …) or **iTerm2** (iTerm2,
  WezTerm); anything else (PDF, HTML, Plotly) opens in your viewer/browser
- **LSP across cells**: diagnostics, completion, hover, definition, references, rename, formatting; IPython
  syntax (`%magic`, `!cmd`, `%%bash`) is hidden from Python servers and restored after formatting
- **More**: variable inspector, cell picker, folding, `:NotebookExport` (nbconvert), `:checkhealth ipynb`

## 🧩 How It Works

- **Notebook mode**: the notebook is rendered into one read-only buffer for navigating and managing cells
- **Cell mode**: `i`/`a`/`o`/`<CR>` edit the current cell in its own buffer (overlay or split); edits sync back

All code cells are also mirrored into a hidden "shadow" file that language servers attach to, line-for-line with
the notebook, so LSP requests from either view are proxied there. A small Python process (`python/kernel_bridge.py`)
talks to Jupyter kernels with `jupyter_client` on one asyncio loop.

## ⚡️ Requirements

- Neovim 0.10+ (0.12+ for Sixel/iTerm2 images)
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) (the notebook parser compiles on first load)
- Python 3.9+ with `jupyter_client` and `ipykernel` for running code:

  ```sh
  python -m pip install jupyter_client ipykernel
  ```

  A `.venv` / `venv` next to (or above) the notebook is found automatically.

***Optional:***

- [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) or `vim.lsp.config` servers for LSP features
- [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) for language icons in cell borders
- [snacks.nvim](https://github.com/folke/snacks.nvim) for inline images in kitty / Ghostty / WezTerm
- ImageMagick (`magick`) for Sixel images (Windows Terminal: `winget install ImageMagick.ImageMagick`)
- [iron.nvim](https://github.com/Vigemus/iron.nvim) to run cells in a REPL when there is no Jupyter kernel
- `nbconvert` for `:NotebookExport`, `jupyter_server` if you want to run a Jupyter server yourself

Run `:checkhealth ipynb` to see what is set up (it checks the same Python the kernel will use).

## 📦 Installation

### lazy.nvim

```lua
{
  "ajbucci/ipynb.nvim", -- or your fork
  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    "neovim/nvim-lspconfig",
    -- "nvim-tree/nvim-web-devicons", -- optional, language icons
    -- "folke/snacks.nvim",           -- optional, kitty-protocol images
  },
  lazy = false, -- must own *.ipynb before the first notebook is read
  opts = {},
}
```

### Manual

1. Add the plugin to your runtime path
2. Call `require("ipynb").setup()` (parser auto-compiles on first load)

## 🚀 Usage

1. **Open** a notebook: `nvim notebook.ipynb`, `:e notebook.ipynb`, or `:NotebookCreate name [kernel]`
2. **Edit** a cell: put the cursor on it (`]]` / `[[` jump between cells) and press `i`, `a`, `o` or `<CR>`;
   `<Esc>` returns to Notebook mode. `<C-j>` / `<C-k>` edit the next / previous cell.
3. **Start a kernel**: `:NotebookKernelStart` (`<leader>ks`), or `:NotebookServerConnect <url>` for a
   Jupyter server
4. **Run**: `<C-CR>` (stay), `<S-CR>` (next), `<M-CR>` (insert below); in the cell editor, select lines and
   press `<C-CR>` to run just those
5. **Outputs** show under the cell; `:NotebookOutput` (`<leader>ko`) opens them in a float to copy,
   `:NotebookOpenOutput` opens images / HTML / plots in your viewer
6. **Inspect** variables with `:NotebookInspect` (`<leader>kh`) or `:NotebookInspectCell` (`<leader>kv`)

### Split editor

```lua
opts = { float = { layout = "split", split = { position = "right", size = 0.45 } } }
```

The cell opens in a split beside the notebook. Scroll the notebook side freely while editing (it is read-only
while focused), and pressing `i` on another cell reuses the same split.

## 🧪 Compatibility with other notebook apps

| | JupyterLab | Colab | Databricks | ipynb.nvim |
|---|---|---|---|---|
| Open/save without changing the file | ✓ | ✓ | ✓ | ✓ byte-identical, CRLF kept |
| Markdown attachments (pasted images) | ✓ | ✓ | ✓ | kept on save |
| Cell tags / titles | tags | `#@title` | titles | shown on the cell border; tags editable |
| Hide code / hide outputs | ✓ | forms | ✓ | ✓ same metadata (`jupyter.source_hidden` / `outputs_hidden`) |
| Run all / above / below / selection, restart & run all | ✓ | ✓ | ✓ | ✓ |
| Stop after an error | ✓ | ✓ | ✓ | ✓ (queued cells are aborted) |
| Run time per cell | ✓ | ✓ | ✓ | ✓ (optionally saved like JupyterLab: `kernel.record_timing`) |
| `clear_output`, display updates, progress bars | ✓ | ✓ | ✓ | ✓ |
| Magics / shell (`%time`, `!pip`, `%%bash`) | ✓ | ✓ | `%sql` etc. | run by the kernel; hidden from Python LSPs |
| Remote compute | server | Colab VMs | clusters | any Jupyter server; Databricks via [Databricks Connect](https://docs.databricks.com/dev-tools/databricks-connect/index.html) in a local kernel |
| Widgets (ipywidgets) | ✓ | ✓ | ✓ | not in a terminal |

Colab runtimes can't be driven from outside Colab, so Colab notebooks are opened, edited and saved here and run
on a local or Jupyter-server kernel.

## 📝 Persistent Markdown Rendering

Markdown cells receive Tree-sitter highlighting out of the box. To render headings, links, lists, tables, and
LaTeX persistently in Notebook mode, use a Markdown renderer that supports injected Tree-sitter languages and
attach it to the `ipynb` filetype. For
[render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim):

```lua
{
  "MeanderingProgrammer/render-markdown.nvim",
  ft = { "markdown", "ipynb" },
  opts = {
    file_types = { "markdown", "ipynb" },
    overrides = {
      filetype = {
        -- Optional: keep the cursor line rendered in the notebook facade.
        ipynb = { anti_conceal = { enabled = false } },
      },
    },
  },
}
```

For [markview.nvim](https://github.com/OXY2DEV/markview.nvim), add `ipynb` to `preview.filetypes`. The notebook
buffer must remain `filetype=ipynb`.

## 🐍 Python Environment *(for Jupyter kernels)*

The kernel bridge runs with the first Python found from:

1. **Path argument** passed to `:NotebookKernelStart`
2. **`kernel.python_path`** in config
3. **Virtual environment** found by walking up from the notebook's directory (`.venv`, `venv`, `.virtualenv`,
   `env`; `Scripts\python.exe` on Windows, `bin/python` elsewhere)
4. **System Python** (`python3`, then `python`; on Windows `python` first, and the Microsoft Store
   `python3` stub is skipped)

That Python needs `jupyter_client`; the kernel itself is whatever the notebook's kernelspec names
(`:NotebookListKernels`, `:NotebookSetKernel`).

## 🗂️ Other languages

The language comes from the notebook metadata (and from the kernel once it starts) and drives highlighting, the
shadow file's language server, and execution. Install the Jupyter kernel for the language
(IRkernel, IJulia, gonb, evcxr, …) and its language server.

```vim
:NotebookCreate analysis ir
:NotebookSetKernel julia-1.10
```

**No kernel for the language?** With [iron.nvim](https://github.com/Vigemus/iron.nvim) installed, running a cell
with no kernel connected sends it to iron's REPL for the notebook language (`repl.fallback = true`); output
shows in the REPL window. `:NotebookReplSend` sends a cell explicitly.

> [!WARNING]
> `R.nvim` is unsupported! Please disable it when using this plugin.

## 🌐 Jupyter servers

```vim
:NotebookServerConnect http://localhost:8888/lab?token=abc          " pick a running kernel or start one
:NotebookServerConnect https://hub.example.com/user/me/?token=abc python3
```

Paste the URL from JupyterLab or JupyterHub (frontend paths like `/lab` are ignored). The token can also come
from `$JUPYTER_TOKEN`, which keeps it out of your command history. Interrupt and restart go through the server;
disconnecting only shuts down kernels ipynb.nvim started.

## 🖼️ Images

| Terminal | Protocol | Needs |
|---|---|---|
| kitty, Ghostty | kitty placeholders | snacks.nvim |
| WezTerm, iTerm2 | iTerm2 (OSC 1337) | Neovim 0.12+ |
| Windows Terminal 1.22+, foot, mlterm | Sixel | Neovim 0.12+, ImageMagick |
| anything else | — | `:NotebookOpenOutput` opens it in your viewer |

`images.backend = "auto"` picks one from the terminal; set `"sixel"`, `"iterm2"`, `"kitty"` or `"none"` to choose.
Sixel/iTerm2 images are drawn only when they fit in the window and redrawn as you scroll.

## ⚙️ Configuration

<details><summary>Default Options</summary>

<!-- config:start -->
```lua
require("ipynb").setup({
  float = {
    layout = "overlay", -- "overlay" = edit on top of the cell, "split" = edit in a split beside the notebook
    split = { position = "right", size = 0.45 }, -- used when layout = "split"
    show_line_numbers = false, -- line numbers in overlay mode (facade numbers visible behind)
  },
  keymaps = {
    -- Direct facade keys (high-frequency)
    next_cell = "]]",
    prev_cell = "[[",
    jump_to_cell = "<leader>kj",
    cut_cell = "dd",
    paste_cell_below = "p",
    paste_cell_above = "P",
    move_cell_down = "<M-j>",
    move_cell_up = "<M-k>",
    execute_cell = "<C-CR>",
    execute_and_next = "<S-CR>",
    execute_and_insert = "<M-CR>",
    interrupt_kernel = "<C-c>",
    -- <leader>k menu (notebook operations)
    add_cell_above = "<leader>ka",
    add_cell_below = "<leader>kb",
    make_markdown = "<leader>km",
    make_code = "<leader>ky",
    make_raw = "<leader>kr",
    open_output = "<leader>ko",
    clear_output = "<leader>kc",
    clear_all_outputs = "<leader>kC",
    menu_execute_cell = "<leader>kx",
    menu_execute_and_next = "<leader>kX",
    execute_all_below = nil, -- Unmapped by default; set to e.g. '<leader>kA' to enable
    execute_all_above = nil, -- Run all cells above the current one (unmapped)
    execute_all = nil, -- Run all cells (unmapped)
    restart_and_run_all = nil, -- Restart kernel, then run all cells (unmapped)
    copy_cell = "yy", -- Copy cell to the cell register
    merge_cell_below = nil, -- Merge current cell with the one below (unmapped)
    split_cell = nil, -- Split the edited cell at the cursor (cell editor, unmapped)
    toggle_source_hidden = nil, -- Hide/show the cell's code, saved like JupyterLab (unmapped)
    toggle_outputs_hidden = nil, -- Hide/show the cell's outputs, saved like JupyterLab (unmapped)
    open_output_external = nil, -- Open image/HTML output in the system viewer (unmapped)
    edit_tags = nil, -- Edit the cell's tags (unmapped)
    repl_send_cell = nil, -- Send cell (or selection in the cell editor) to the iron.nvim REPL (unmapped)
    kernel_interrupt = "<leader>ki",
    kernel_restart = "<leader>k0",
    kernel_start = "<leader>ks",
    kernel_shutdown = "<leader>kS",
    kernel_info = "<leader>kn",
    fold_toggle = "<leader>kf",
    variable_inspect = "<leader>kh",
    cell_variables = "<leader>kv",
    toggle_auto_hover = "<leader>kH",
    -- Note: i, a, I, A, o, O, <CR> are hardcoded for edit mode entry
    -- Note: LSP keymaps (gd, gr, K, etc.) work via API interception in lsp.lua
  },
  highlights = {
    border = "Comment",
    border_hover = "Special",
    border_active = "Number",
    exec_count = "Number",
    output = "Comment",
    output_error = "DiagnosticError",
    output_stderr = "DiagnosticWarn",
    executing = "DiagnosticWarn",
    queued = "DiagnosticHint",
    hint = "Comment",
  },
  border_hints = {
    enabled = true,
    show_on_hover = true,
    show_on_edit = true,
  },
  repl = {
    fallback = true, -- with no Jupyter kernel, run cells in an iron.nvim REPL (if installed)
  },
  output = {
    max_lines = 100, -- inline text lines per cell; the rest via open_output (0 = no limit)
  },
  kernel = {
    auto_connect = false,
    show_status = true,
    python_path = nil, -- Custom Python path (otherwise auto-discovered)
    record_timing = false, -- Save cell start/end times in metadata (JupyterLab format)
  },
  images = {
    enabled = true,
    backend = "auto", -- "auto", "kitty" (snacks.nvim), "sixel", "iterm2" or "none"
    cell_size = { 10, 20 }, -- terminal cell size in pixels, used to size Sixel images
    max_rows = 20, -- tallest inline image (Sixel / iTerm2), in rows
    cache_dir = vim.fn.stdpath("cache") .. "/ipynb.nvim",
    max_width = nil, -- nil = window width minus sign/number columns
    max_height = nil, -- nil = window height minus scrolloff minus 1
  },
  inspector = {
    close = { "q", "<Esc>" }, -- Keys to close inspector window
    inspect = { "K", "<CR>" }, -- Keys to inspect variable under cursor
    auto_hover = {
      enabled = false, -- Auto-show variable hover on CursorHold
      delay = 500, -- Delay in milliseconds before showing hover
    },
  },
  folding = {
    hide_output = false, -- Include end marker in fold to hide output when folded
  },
  format = {
    enabled = true, -- Wrap vim.lsp.buf.format() to work with notebooks
    trailing_blank_lines = 0, -- Max trailing blank lines to keep after formatting
  },
  shadow = {
    location = "temp", -- "temp" (default) or "workspace"
    dir = ".ipynb.nvim",
    debounce_ms = 400,
  },
})
```
<!-- config:end -->

</details>

## ⌨️ Commands

| Command | Description | Config key | Default keymap |
|---------|-------------|--------|---------|
| `:NotebookCreate [path] [kernel]` | Create new notebook | | |
| `:NotebookSave` | Save notebook | | |
| `:NotebookInfo` | Show notebook and cell info | | |
| `:NotebookJumpToCell` | Open cell picker | `jump_to_cell` | `<leader>kj` |
| `:NotebookInsertCellBelow` | Insert cell below | `add_cell_below` | `<leader>kb` |
| `:NotebookInsertCellAbove` | Insert cell above | `add_cell_above` | `<leader>ka` |
| `:NotebookDeleteCell` | Delete current cell | | |
| `:NotebookCutCell` | Cut cell to register | `cut_cell` | `dd` |
| `:NotebookCopyCell` | Copy cell to register | `copy_cell` | `yy` |
| `:NotebookPasteCellBelow` | Paste cell below | `paste_cell_below` | `p` |
| `:NotebookPasteCellAbove` | Paste cell above | `paste_cell_above` | `P` |
| `:NotebookMoveCellUp` | Move cell up | `move_cell_up` | `<M-k>` |
| `:NotebookMoveCellDown` | Move cell down | `move_cell_down` | `<M-j>` |
| `:NotebookMergeCellBelow` | Merge with the cell below | `merge_cell_below` | |
| `:NotebookSplitCell` | Split cell at cursor | `split_cell` (cell editor) | |
| `:NotebookToggleCellType` | Toggle code/markdown | | |
| `:NotebookMakeMarkdown` | Convert to markdown | `make_markdown` | `<leader>km` |
| `:NotebookMakeCode` | Convert to code | `make_code` | `<leader>ky` |
| `:NotebookMakeRaw` | Convert to raw | `make_raw` | `<leader>kr` |
| `:NotebookCellTags [tags…]` | Set / edit cell tags | `edit_tags` | |
| `:NotebookToggleSourceHidden` | Hide/show cell code | `toggle_source_hidden` | |
| `:NotebookToggleOutputsHidden` | Hide/show cell outputs | `toggle_outputs_hidden` | |
| `:NotebookExecuteCell` | Execute cell, stay | `execute_cell` | `<C-CR>` |
| `:NotebookExecuteAndNext` | Execute cell, move next | `execute_and_next` | `<S-CR>` |
| `:NotebookExecuteAllAbove` | Execute cells above | `execute_all_above` | |
| `:NotebookExecuteAllBelow` | Execute current and below | `execute_all_below` | |
| `:NotebookExecuteAll` | Execute all code cells | `execute_all` | |
| `:NotebookRestartAndRunAll` | Restart kernel, run all | `restart_and_run_all` | |
| `:NotebookReplSend` | Send cell to the iron.nvim REPL | `repl_send_cell` | |
| `:NotebookOutput` | Open output in float | `open_output` | `<leader>ko` |
| `:NotebookOpenOutput` | Open image/HTML/plot externally | `open_output_external` | |
| `:NotebookClearOutput` | Clear cell output | `clear_output` | `<leader>kc` |
| `:NotebookClearAllOutputs` | Clear all outputs | `clear_all_outputs` | `<leader>kC` |
| `:NotebookFoldCell` | Toggle cell fold | `fold_toggle` | `<leader>kf` |
| `:NotebookFoldAll` | Fold all cells | | |
| `:NotebookUnfoldAll` | Unfold all cells | | |
| `:NotebookFormatCell` | Format cell via LSP | | |
| `:NotebookFormatAll` | Format all code cells | | |
| `:NotebookExport {format}` | Export with nbconvert (html, pdf, script, markdown, …) | | |
| `:NotebookKernelStart [python]` | Start kernel | `kernel_start` | `<leader>ks` |
| `:NotebookKernelConnect <file>` | Connect to kernel connection file | | |
| `:NotebookServerConnect <url> [kernel]` | Use a kernel on a Jupyter server | | |
| `:NotebookSetKernel <name>` | Set kernelspec | | |
| `:NotebookListKernels` | List available Jupyter kernels | | |
| `:NotebookKernelInterrupt` | Interrupt execution | `interrupt_kernel` | `<C-c>` |
| `:NotebookKernelRestart` | Restart kernel | `kernel_restart` | `<leader>k0` |
| `:NotebookKernelShutdown` | Shutdown kernel | `kernel_shutdown` | `<leader>kS` |
| `:NotebookKernelStatus` | Show kernel status | `kernel_info` | `<leader>kn` |
| `:NotebookInspect` | Inspect variable at cursor | `variable_inspect` | `<leader>kh` |
| `:NotebookInspectCell` | Show all cell variables | `cell_variables` | `<leader>kv` |
| `:NotebookToggleAutoHover` | Toggle auto-hover | `toggle_auto_hover` | `<leader>kH` |

In the cell editor: `<Esc>` back to the notebook, `<C-j>`/`<C-k>` next/previous cell, `u`/`<C-r>` notebook-wide
undo, and `<C-CR>` on a visual selection runs just the selection.

Note: `vim.lsp.buf.format()` is wrapped to work with notebooks automatically. Disable with `format.enabled = false`.

## 🚥 Statusline

The plugin provides a statusline component showing kernel status. Add it to your statusline (e.g., lualine):

```lua
require("lualine").setup({
  sections = {
    lualine_x = {
      {
        require("ipynb.kernel").statusline,
        cond = require("ipynb.kernel").statusline_visible,
        color = require("ipynb.kernel").statusline_color,
      },
    },
  },
})
```

Shows the language icon + `IDLE` (green), `BUSY` (yellow) or `DISC` (red). Disable with
`kernel.show_status = false`.

## 🩺 Troubleshooting

**Start with** `:checkhealth ipynb`.

**Parser not found** — it compiles on first load. If that was interrupted, tree-sitter may report a stale lock
file under `~/AppData/Local/tree-sitter/lock` (Windows) / `~/.cache/tree-sitter/lock`; remove it and restart,
or run `:TSInstall! ipynb`.

**Kernel won't start** — `:NotebookKernelStatus` shows the Python used; it needs `jupyter_client` and the
kernel (`ipykernel` for Python). On Windows make sure it isn't the Microsoft Store `python3` stub (it is skipped
automatically; set `kernel.python_path` if you use a different interpreter).

**Imports unresolved in diagnostics but code runs** — the language server and the kernel can use different
Pythons. Point your Python LSP at the kernel's interpreter, and consider `shadow.location = "workspace"` so the
server sees your project layout.

**`input()` appears stuck** — the kernel waits for stdin: type in the floating prompt and press `<CR>`
(`<Esc>`/`<C-c>` cancels by interrupting the kernel).

**Images don't show** — check the table in [Images](#️-images). Windows Terminal needs 1.22+ and ImageMagick;
inside tmux, kitty images need `allow-passthrough on`. If an image is the wrong size with Sixel, set
`images.cell_size` to your font's cell size in pixels. `:NotebookOpenOutput` always works.

**`<C-CR>` / `<S-CR>` do nothing** — your terminal may not send them distinctly; use `<leader>kx` /
`<leader>kX`, or remap `execute_cell` / `execute_and_next`.

## 🧪 Development

```sh
nvim --headless -l tests/run_all.lua
```

Set `IPYNB_TEST_PYTHON` to a Python with `jupyter_client`, `ipykernel` and `pytest` (and optionally
`jupyter_server`, `nbconvert`) to include the real-kernel, Jupyter-server and Python bridge tests;
`IPYNB_TEST_KERNELS=ir,gonb` adds other languages (`tests/test_kernels_multi.lua`). `IPYNB_TEST_LAYOUT=split`
runs any suite with the split editor. See `CONTRIBUTING.md` and `doc/ARCHITECTURE.md`.

## 🗺️ Roadmap

🚧 **Not Tested (may or may not work):**

- Semantic tokens (`textDocument/semanticTokens`), document links

🚫 **Not Supported:**

- Code actions (`textDocument/codeAction`) — they can edit ranges across cell boundaries
- ipywidgets and other JavaScript outputs (need a browser; `:NotebookOpenOutput` opens HTML there)
- The Jupyter debugger protocol (use nvim-dap with debugpy on the code instead)
