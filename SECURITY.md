# Security policy

## Supported versions

Security fixes go into the latest release. Update to it before reporting:
`:Org version` shows what you run, and the
[releases](https://github.com/xheisenbugx/org.nvim/releases) page lists the
latest.

## Reporting a vulnerability

Please report it in private, not in a public issue:

1. Open the [Security tab](https://github.com/xheisenbugx/org.nvim/security)
   of the repository.
2. Choose **Report a vulnerability** and describe the problem: the org.nvim
   and Neovim versions, a small org file or config that shows it, and what
   happens.

You should get an answer within a week. Once a fix is released, the report
is published as a security advisory that credits you, unless you'd rather
not be named.

## What counts

Org files are often shared, so opening, viewing or exporting a file you
didn't write must not run code or reach the network without asking. With
the default options:

| What a file can ask for | Default | Option |
| --- | --- | --- |
| Running a source block | asks first | `babel.confirm_evaluate` |
| Following a `shell:` link | asks first | `links.confirm_shell` |
| Following an `elisp:` link | asks first | `links.confirm_elisp` |
| Downloading a URL in `#+SETUPFILE` or `#+INCLUDE` | asks first | `resource_download_policy` |
| Showing the image of an http(s) link | never downloads | `ui.images.remote` |
| Setting export options with `#+BIND` | ignored | `export.allow_bind_keywords` |

A way around one of these is a vulnerability. So is a file that runs a
program, writes outside the places it names or sends data anywhere just by
being opened, folded, shown in the agenda or exported.

These aren't vulnerabilities:

- code you agreed to run (a block you confirmed, a link you followed and
  said yes to);
- what your own configuration runs (capture templates, hooks, custom
  agenda commands, Babel languages);
- behaviour after you turned one of the options above off.

If you aren't sure, report it in private anyway.
