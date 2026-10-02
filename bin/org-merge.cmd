@echo off
rem Git merge driver for Org files on Windows (see bin/org-merge):
rem   git config merge.org.driver "C:/path/to/org.nvim/bin/org-merge.cmd --marker-size=%L --ours-label=%X --theirs-label=%Y %O %A %B %P"
rem %NVIM_BIN% picks the Neovim binary (default: nvim on %PATH%).
setlocal
set "ORG_NVIM=%NVIM_BIN%"
if not defined ORG_NVIM set "ORG_NVIM=nvim"
"%ORG_NVIM%" --headless -u NONE -i NONE -l "%~dp0..\lua\org\extensions\merge\driver.lua" %*
exit /b %ERRORLEVEL%
