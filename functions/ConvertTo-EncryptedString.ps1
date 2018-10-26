Function ConvertTo-EncryptedString {
    [CmdletBinding(SupportsShouldProcess)]
    <#
    .SYNOPSIS
    Converts a SecureString object to an encrypted string.
    
    .DESCRIPTION
    Converts a SecureString object to an encrypted string with an option to use a custom key.
    
    Key path can be defined by:
    PS> Get/Set-DBODefaultSetting -Name security.encryptionkey

    Custom key is enforced in a Unix environment by a default setting security.usecustomencryptionkey
    PS> Get/Set-DBODefaultSetting -Name security.usecustomencryptionkey
   
    .PARAMETER String
    SecureString to be encrypted
    
    .PARAMETER Confirm
    Prompts to confirm certain actions

    .PARAMETER WhatIf
    Shows what would happen if the command would execute, but does not actually perform the command

    .EXAMPLE
    # Converts a password provided by user to an encrypted string
    ConvertTo-EncryptedString -String (Read-Host -AsSecureString)
    
    .NOTES
    
    #>
    Param (
        [Parameter(ValueFromPipeline, Mandatory)]
        [secureString]$SecureString
    )
    if (Get-DBODefaultSetting -Name security.usecustomencryptionkey -Value) {
        $key = Get-EncryptionKey
        if (!$key -and $PSCmdlet.ShouldProcess("Generating a new encryption key")) {
            $key = New-EncryptionKey
        }
        $PSBoundParameters += @{ Key = $key }
    }
    try {
        ConvertFrom-SecureString @PSBoundParameters
    }
    catch {
        Stop-PSFFunction "Failed to encrypt the secure string" -Exception $_ -EnableException $true
    }
}