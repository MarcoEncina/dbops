Function Convert-DirectorySeparator {
    Param (
        [string]$Path
    )
    $newPath = switch (([System.IO.Path]::DirectorySeparatorChar)) {
        '\' { $path.Replace('/', $_) }
        '/' { $path.Replace('\', $_) }
        default { $path }
    }
    return $newPath
}
#Adding short alias for tests
if (-Not (Get-Alias | Where-Object Name -eq cds)) { New-Alias -Name cds -Value Convert-DirectorySeparator }