# constants
if (Test-Path "$PSScriptRoot\constants.local.ps1") {
    Write-Verbose "tests\constants.local.ps1 found."
    . "$PSScriptRoot\constants.local.ps1"
}
else {
    $script:instance1 = $env:mssql_instance
}