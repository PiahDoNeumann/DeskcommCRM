# Atalho do PowerShell para docker/deskcrm/local.sh.
# No PowerShell, `bash` é o do WSL; o script precisa do Git Bash.
#
#   .\docker\deskcrm\local.ps1 up|down|status|logs|build|baseline|reset

$gitBash = Join-Path (Split-Path (Split-Path (Get-Command git).Source)) "bin\bash.exe"
if (-not (Test-Path $gitBash)) {
    Write-Error "Git Bash não encontrado em $gitBash"
    exit 1
}

& $gitBash (Join-Path $PSScriptRoot "local.sh") @args
exit $LASTEXITCODE
