-- Options: Babel.
--
-- One part of `require("org.config").defaults`, merged in the order of
-- `M.parts` in lua/org/config/init.lua. Keys keep the indentation of the
-- full table: `:Org customize` reads these files for the options and the
-- `---` documentation above each one.

---@class org.config.Resolved
local defaults = {
  ---------------------------------------------------------------------------
  -- Babel
  ---------------------------------------------------------------------------
  babel = {
    -- Ask before evaluating: true, false, or a function(lang, body) that
    -- returns true to ask (org-confirm-babel-evaluate)
    confirm_evaluate = true,
    -- Results of this many lines or more use an example block
    -- (org-babel-min-lines-for-block-output)
    min_lines_for_block_output = 10,
    -- Kill an evaluation after this many ms (no Emacs counterpart)
    timeout = 30000,
    -- Every interactive evaluation writes a placeholder result at once and
    -- replaces it when done, like `:async yes` on a session block
    -- (org-babel-comint-async); `:async no` opts a block out. Evaluations
    -- never block Neovim either way.
    async = false,
    -- Frames of the spinner shown after a running block's first line
    -- (virtual text); false: a still "executing…"
    spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    -- Milliseconds between spinner frames
    spinner_interval = 100,
    -- Evaluate code when exporting (org-export-use-babel)
    evaluate_on_export = true,
    -- C-c C-c on a block does not evaluate it (org-babel-no-eval-on-ctrl-c-ctrl-c)
    no_eval_on_ctrl_c_ctrl_c = false,
    -- (org-babel-default-header-args)
    default_header_args = {
      session = "none",
      results = "replace",
      exports = "code",
      cache = "no",
      noweb = "no",
      hlines = "no",
      tangle = "no",
    },
    -- Header args of inline src blocks (org-babel-default-inline-header-args)
    default_inline_header_args = {
      session = "none",
      results = "replace",
      exports = "results",
      hlines = "yes",
    },
    -- Header args of #+CALL lines and call_ (org-babel-default-lob-header-args)
    default_lob_header_args = { exports = "results" },
    -- Keyword of results lines (org-babel-results-keyword)
    results_keyword = "RESULTS",
    -- Inline results inside {{{results(...)}}} (org-babel-inline-result-wrap)
    inline_result_wrap = "=%s=",
    -- Write "(date) " before :cache hashes (org-babel-hash-show-time)
    hash_show_time = false,
    -- Noweb reference delimiters (org-babel-noweb-wrap-start / -end)
    noweb_wrap_start = "<<",
    noweb_wrap_end = ">>",
    -- Tangle link comments use paths relative to the tangled file
    -- (org-babel-tangle-use-relative-file-links)
    tangle_use_relative_file_links = true,
    -- Link comments around tangled blocks, %link / %source-name / %file /
    -- %start-line / %end-line (org-babel-tangle-comment-format-beg / -end)
    tangle_comment_format_beg = "[[%link][%source-name]]",
    tangle_comment_format_end = "%source-name ends here",
    -- Base mode for symbolic :tangle-mode values like u+x, octal string
    -- (org-babel-tangle-default-file-mode)
    tangle_default_file_mode = "644",
    -- Extensions of `:tangle yes` files by language, added to Emacs' list
    -- (org-babel-tangle-lang-exts)
    tangle_lang_exts = {},
    -- Save the Org buffer before tangling (org-babel-pre-tangle-hook)
    tangle_save_buffer = true,
    -- Write tangle comments as they are, without comment syntax
    -- (org-babel-tangle-uncomment-comments)
    tangle_uncomment_comments = false,
    -- Overwrite an existing tangle target: "auto" (delete it first only when
    -- read-only), true (always delete and recreate), false (replace the
    -- contents) (org-babel-tangle-remove-file-before-write)
    tangle_remove_file_before_write = "auto",
    -- function(text) -> text applied to the Org text of :comments org|both;
    -- nil removes its common indentation (org-babel-process-comment-text)
    process_comment_text = nil,
    -- Write #+BEGIN_EXAMPLE / #+END_EXAMPLE around results
    -- (org-babel-uppercase-example-markers)
    uppercase_example_markers = false,
    -- Templates of exported code, filled with %lang, %name, %body, %switches,
    -- %header-args and %<header argument> (org-babel-exp-code-template,
    -- org-babel-exp-inline-code-template), and of exported #+CALL lines and
    -- call_ objects, with %line (org-babel-exp-call-line-template)
    exp_code_template = "#+begin_src %lang%switches%header-args\n%body\n#+end_src",
    exp_inline_code_template = "src_%lang[%switches%header-args]{%body}",
    exp_call_line_template = "",
    -- Languages run as a shell, like sh (org-babel-shell-names)
    shell_names = { "sh", "bash", "zsh", "fish", "csh", "ash", "dash", "ksh", "mksh", "posh" },
    -- Shell blocks without :results words give their output; false: their
    -- exit status (org-babel-shell-results-defaults-to-output)
    shell_results_defaults_to_output = true,
    -- Languages that can run, { cmd, ext, default_header_args }
    -- (org-babel-load-languages; default_header_args is
    -- org-babel-default-header-args:LANG). Emacs enables only emacs-lisp,
    -- which cannot run in Neovim, so the common interpreters are enabled.
    languages = {
      sh = { cmd = "sh" },
      shell = { cmd = "sh" },
      bash = { cmd = "bash" },
      zsh = { cmd = "zsh" },
      fish = { cmd = "fish" },
      -- hline_to: an hline of a table variable (org-babel-python-hline-to);
      -- None_to: a None of a list result (org-babel-python-None-to);
      -- session_cmd: the REPL of sessions, as it is (org-babel-python-command-session)
      python = { cmd = "python3", ext = "py", hline_to = "None", None_to = "hline", session_cmd = nil },
      python3 = { cmd = "python3", ext = "py" },
      -- evaluated inside Neovim; another cmd ("lua", "luajit") runs it
      -- like ob-lua (org-babel-lua-command). hline_to / None_to /
      -- multiple_values_separator: org-babel-lua-*
      lua = { cmd = "nvim", ext = "lua", hline_to = "None", None_to = "hline", multiple_values_separator = ", " },
      js = { cmd = "node", ext = "js" },
      javascript = { cmd = "node", ext = "js" },
      typescript = { cmd = "npx tsx", ext = "ts" },
      ts = { cmd = "npx tsx", ext = "ts" },
      -- org-babel-ruby-hline-to / org-babel-ruby-nil-to
      ruby = { cmd = "ruby", ext = "rb", hline_to = "nil", nil_to = "hline" },
      perl = { cmd = "perl", ext = "pl" },
      php = { cmd = "php", ext = "php" },
      r = { cmd = "Rscript", ext = "R" },
      R = { cmd = "Rscript", ext = "R" },
      go = { cmd = "go run", ext = "go" },
      rust = { cmd = "rust-script", ext = "rs" },
      sqlite = { cmd = "sqlite3", ext = "sql" },
      -- :engine postgresql|mysql|... runs the engine's client (ob-sql)
      sql = { ext = "sql" },
      -- ob-C: compiled with :flags, :libs, :includes, :defines, :main
      C = { cmd = "gcc", ext = "c" },
      ["C++"] = { cmd = "g++", ext = "cpp" },
      cpp = { cmd = "g++", ext = "cpp" },
      D = { cmd = "rdmd", ext = "d" },
      awk = { cmd = "awk -f", ext = "awk" },
      -- ports of ob-LANG.el (see |org-babel-languages|); the other keys are
      -- that file's options
      plantuml = {
        default_header_args = { results = "file", exports = "results" },
        exec_mode = "jar", -- org-plantuml-exec-mode: "jar" or "plantuml"
        jar_path = "", -- org-plantuml-jar-path
        executable_path = "plantuml", -- org-plantuml-executable-path
        args = { "-headless" }, -- org-plantuml-args
        svg_text_to_path = false, -- org-babel-plantuml-svg-text-to-path
      },
      ditaa = {
        default_header_args = { results = "file graphics", exports = "results", ["file-ext"] = "png" },
        exec_mode = "jar", -- org-ditaa-default-exec-mode: "jar" or "ditaa"
        exec = "ditaa", -- org-ditaa-exec
        java_exec = "java", -- org-ditaa-java-exec
        jar_path = "", -- org-ditaa-jar-path
        eps_jar_path = nil, -- org-ditaa-eps-jar-path (nil: DitaaEps.jar next to jar_path)
      },
      -- backend (org-babel-clojure-backend): "babashka", "clojure-cli" or
      -- "nbb"; nil picks babashka or clojure-cli when installed.
      -- babashka_command / cli_command / nbb_command: ob-clojure-*-command
      -- (nil: bb, clojure -M, nbb or npx nbb found on $PATH)
      clojure = { ext = "clj", default_ns = "user" }, -- default_ns: org-babel-clojure-default-ns
      -- backend (org-babel-clojurescript-backend): nil is nbb when installed
      clojurescript = { ext = "cljs" },
      -- org-babel-csharp-*: compiler; default_target_framework (nil: "netN.0"
      -- of the newest SDK); additional_project_flags (XML); functions
      -- generate_compile_command(project, bin_dir) and
      -- generate_restore_command(project) returning shell commands
      csharp = { ext = "cs", compiler = "dotnet" },
      fortran = { cmd = "gfortran", ext = "F90" }, -- cmd: org-babel-fortran-compiler
      java = {
        default_header_args = { results = "output", dir = "." },
        cmd = "java", -- org-babel-java-command
        compiler = "javac", -- org-babel-java-compiler
        hline_to = "null", -- org-babel-java-hline-to
        null_to = "hline", -- org-babel-java-null-to
      },
      groovy = { cmd = "groovy" }, -- org-babel-groovy-command
      -- cmd: the interpreter of blocks (Emacs: an inf-haskell session);
      -- compiler: org-babel-haskell-compiler (:compile yes);
      -- lhs2tex: org-babel-haskell-lhs2tex-command
      haskell = {
        default_header_args = { padline = "no" },
        cmd = "ghci -v0 -ignore-dot-ghci",
        compiler = "ghc",
        lhs2tex = "lhs2tex",
      },
      -- Common Lisp: cmd evaluates in place of SLIME (org-babel-lisp-eval-fn);
      -- dir_fmt: org-babel-lisp-dir-fmt
      lisp = {
        cmd = "sbcl --script",
        ext = "lisp",
        dir_fmt = "(cl:let ((cl:*default-pathname-defaults* #P%S\n)) %%s\n)",
      },
      -- js_filename: org-babel-processing-processing-js-filename; cmd runs
      -- babel_processing_view_sketch (processing-java)
      processing = {
        default_header_args = { results = "html", exports = "results" },
        js_filename = "processing.js",
        cmd = "processing-java",
      },
      -- location: org-babel-screen-location
      screen = {
        default_header_args = {
          results = "silent",
          session = "default",
          cmd = "sh",
          terminal = "xterm",
          screenrc = "/dev/null",
        },
        location = "screen",
      },
      -- impl: the implementation without a :scheme header (Geiser's
      -- default); commands: implementation -> command; null_to:
      -- org-babel-scheme-null-to
      scheme = { impl = "guile", commands = {}, null_to = "hline" },
      julia = { cmd = "julia" }, -- org-babel-julia-command
      -- org-babel-latex-*: preamble, begin_env and end_env are strings or
      -- functions(header_args) returning one; htlatex, htlatex_packages;
      -- pdf_svg_process (%f the PDF, %O the SVG); process_alist = { png =
      -- {...} } like ui.latex_preview.processes (nil: latex + dvipng)
      latex = {
        ext = "tex",
        default_header_args = { results = "latex", exports = "results" },
        preamble = "\\documentclass[preview]{standalone}\n",
        begin_env = "\\begin{document}",
        end_env = "\\end{document}",
        htlatex = "htlatex",
        htlatex_packages = { "[usenames]{color}", "{tikz}", "{color}", "{listings}", "{amsmath}" },
        pdf_svg_process = "inkscape --pdf-poppler --export-area-drawing --export-text-to-path "
          .. "--export-plain-svg --export-filename=%O %f",
        process_alist = nil,
      },
      -- commands: org-babel-lilypond-commands, { lilypond, PDF viewer, MIDI
      -- player } (nil: the platform's default); the other keys are the
      -- org-babel-lilypond-* variables the toggle commands change
      lilypond = {
        ext = "ly",
        default_header_args = { results = "file", exports = "results" },
        commands = nil,
        arrange_mode = false,
        gen_png = false,
        gen_svg = false,
        gen_html = false,
        gen_pdf = false,
        use_eps = false,
        compile_post_tangle = true,
        display_pdf_post_tangle = true,
        play_midi_post_tangle = true,
      },
      maxima = { cmd = "maxima" }, -- org-babel-maxima-command
      ocaml = { cmd = "ocaml" }, -- org-babel-ocaml-command
      gnuplot = {
        cmd = "gnuplot",
        default_header_args = { results = "file", exports = "results" },
        terms = { eps = "postscript eps" }, -- *org-babel-gnuplot-terms*
      },
    },
    -- emacs-lisp blocks, elisp: links and the Lisp forms the interpreter of
    -- table formulas can't evaluate (macros, capture, diary sexps, headers)
    -- run in a separate Emacs process (`command` false: never)
    emacs_lisp = { command = "emacs", args = { "-Q", "--batch" } },
  },
}

return defaults
