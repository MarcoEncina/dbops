Param (
    [switch]$Batch
)

if ($PSScriptRoot) { $commandName = $MyInvocation.MyCommand.Name.Replace(".Tests.ps1", ""); $here = $PSScriptRoot }
else { $commandName = "_ManualExecution"; $here = (Get-Item . ).FullName }

if (!$Batch) {
    # Is not a part of the global batch => import module
    Import-Module "$here\..\dbops.psd1" -Force
}
else {
    # Is a part of a batch, output some eye-catching happiness
    Write-Host "Running $commandName tests" -ForegroundColor Cyan
}
. "$here\..\internal\functions\New-EncryptionKey.ps1"
. "$here\..\internal\functions\Get-EncryptionKey.ps1"

$keyPath = "$here\etc\tmp_key.key"
$secret = 'MahS3cr#t'
$secureSecret = $secret | ConvertTo-SecureString -AsPlainText -Force

Describe "ConvertFrom-EncryptedString tests" -Tag $commandName, UnitTests {
    BeforeAll {
        Set-DBODefaultSetting -Name security.encryptionkey -Value $keyPath -Temporary
        Set-DBODefaultSetting -Name security.usecustomencryptionkey -Value $true -Temporary
        if (Test-Path $keyPath) { Remove-Item $keyPath -Force }
        New-EncryptionKey 3>$null
    }
    AfterAll {
        if (Test-Path $keyPath) { Remove-Item $keyPath -Force }
        Reset-DBODefaultSetting -Name security.usecustomencryptionkey, security.encryptionkey
    }
    Context "Should return the strings decrypted" {
        It "should re-use existing key and decrypt" {
            $key = [System.IO.File]::ReadAllBytes($keyPath)
            $encString = $secureSecret | ConvertFrom-SecureString -Key $key
            $pwdString = $encString | ConvertFrom-EncryptedString
            [pscredential]::new('a', $pwdString).GetNetworkCredential().Password | Should -Be $secret
        }
    }
    Context "Negative tests" {
        BeforeAll {
            $key = [System.IO.File]::ReadAllBytes($keyPath)
            $encString = $secureSecret | ConvertFrom-SecureString -Key $key
        }
        It "Should fail to decrypt without a key" {
            if (Test-Path $keyPath) { Remove-Item $keyPath -Force }
            { $encString | ConvertFrom-EncryptedString } | Should Throw
        }
        It "Should fail to decrypt without a proper key" {
            if (Test-Path $keyPath) { Remove-Item $keyPath -Force }
            $file = New-Item -Path $keyPath -ItemType File
            [System.IO.File]::WriteAllBytes($keyPath, [byte[]](1, 2))
            { $encString | ConvertFrom-EncryptedString } | Should Throw
        }
    }
}