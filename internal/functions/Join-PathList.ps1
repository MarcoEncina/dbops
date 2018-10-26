Function Join-PathList {
    if ($args.Count -le 1) {
        Stop-PSFFunction -Message "Less than 2 arguments provided" -EnableException $true
    }
    $path = $args[0]
    for ($i = 1; $i -lt $args.Count; $i++) {
        $path = Join-Path $path $args[$i] -ErrorAction Stop
    }
    $path
}
#Adding short alias for tests
if (-Not (Get-Alias | Where-Object Name -eq jpl)) { New-Alias -Name jpl -Value Join-PathList }