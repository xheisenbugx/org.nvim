@echo off
rem org: the org.nvim command line on Windows (see bin/org, `org help` and
rem :h org-extensions-cli). Runs `nvim --headless -l` on
rem lua\org\extensions\cli\main.lua of the checkout this file lives in.
rem %ORG_NVIM_BIN% picks the nvim binary (default: nvim on %PATH%).
setlocal
set "ORG_NVIM=%ORG_NVIM_BIN%"
if not defined ORG_NVIM set "ORG_NVIM=nvim"
"%ORG_NVIM%" --headless -l "%~dp0..\lua\org\extensions\cli\main.lua" %*
exit /b %ERRORLEVEL%
