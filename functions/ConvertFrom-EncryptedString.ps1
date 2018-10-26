Function ConvertFrom-EncryptedString {
    <#
    .SYNOPSIS
    Converts an encrypted string to a SecureString object.
    
    .DESCRIPTION
    Converts an encrypted string to a SecureString object with an option to use a custom key.
    
    Key path can be defined by:
    PS> Get/Set-DBODefaultSetting -Name security.encryptionkey

    Custom key is enforced in a Unix environment by a default setting security.usecustomencryptionkey
    PS> Get/Set-DBODefaultSetting -Name security.usecustomencryptionkey
   
    .PARAMETER String
    String to be decrypted
    
    .PARAMETER Confirm
    Prompts to confirm certain actions

    .PARAMETER WhatIf
    Shows what would happen if the command would execute, but does not actually perform the command

    .EXAMPLE
    # Converts a password provided by user to an encrypted string
    $encrypted = ConvertTo-EncryptedString -String (Read-Host -AsSecureString)
    $decrypted = ConvertFrom-EncryptedString -String $encrypted
    
    .NOTES
    
    #>
    [CmdletBinding(SupportsShouldProcess)]
    Param (
        [Parameter(ValueFromPipeline, Mandatory)]
        [String]$String
    )
    if (Get-DBODefaultSetting -Name security.usecustomencryptionkey -Value) {
        $wi = @{}
        if ($PSCmdlet.ShouldProcess("Getting an encryption key")) {
            $wi += @{ WhatIf = $true }
        }
        $PSBoundParameters += @{ Key = Get-EncryptionKey @wi}
    }
    try {
        ConvertTo-SecureString @PSBoundParameters -ErrorAction Stop
    }
    catch {
        Stop-PSFFunction -Message "Failed to decrypt the secure string" -Exception $_ -EnableException $true
    }
}