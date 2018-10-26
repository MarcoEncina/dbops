﻿Param (
    [switch]$Batch
)

if ($PSScriptRoot) { $commandName = $MyInvocation.MyCommand.Name.Replace(".Tests.ps1", ""); $here = $PSScriptRoot }
else { $commandName = "_ManualExecution"; $here = (Get-Item . ).FullName }

if (!$Batch) {
    # Is not a part of the global batch => import module
    #Explicitly import the module for testing
    Import-Module "$here\..\dbops.psd1" -Force; Get-DBOModuleFileList -Type internal | ForEach-Object { . $_.FullName }
}
else {
    # Is a part of a batch, output some eye-catching happiness
    Write-Host "Running $commandName tests" -ForegroundColor Cyan
}

. "$here\constants.ps1"
. "$here\etc\Invoke-SqlCmd2.ps1"

$workFolder = Join-Path "$here\etc" "$commandName.Tests.dbops"
$unpackedFolder = Join-Path $workFolder 'unpacked'
$logTable = "testdeploymenthistory"
$cleanupScript = "$here\etc\install-tests\Cleanup.sql"
$v1scripts = "$here\etc\install-tests\success\1.sql"
$verificationScript = "$here\etc\install-tests\verification\select.sql"
$packageName = Join-Path $workFolder 'TempDeployment.zip'
$newDbName = "_test_$commandName"

Describe "deploy.ps1 integration tests" -Tag $commandName, IntegrationTests {
    BeforeAll {
        if ((Test-Path $workFolder) -and $workFolder -like '*.Tests.dbops') { Remove-Item $workFolder -Recurse }
        $null = New-Item $workFolder -ItemType Directory -Force
        $null = New-Item $unpackedFolder -ItemType Directory -Force
        $packageName = New-DBOPackage -Path $packageName -ScriptPath $v1scripts -Build 1.0 -Force
        $null = Expand-Archive -Path $packageName -DestinationPath $workFolder -Force
        $dropDatabaseScript = 'IF EXISTS (SELECT * FROM sys.databases WHERE name = ''{0}'') BEGIN ALTER DATABASE [{0}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [{0}]; END' -f $newDbName
        $createDatabaseScript = 'IF NOT EXISTS (SELECT * FROM sys.databases WHERE name = ''{0}'') BEGIN CREATE DATABASE [{0}]; END' -f $newDbName
        $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database master -Query $dropDatabaseScript
        $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database master -Query $createDatabaseScript
    }
    AfterAll {
        $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database master -Query $dropDatabaseScript
        if ((Test-Path $workFolder) -and $workFolder -like '*.Tests.dbops') { Remove-Item $workFolder -Recurse }
    }
    Context "testing deployment of extracted package" {
        BeforeEach {
            $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $cleanupScript
        }
        It "should deploy with a -Configuration parameter" {
            $deploymentConfig = @{
                SqlInstance        = $script:instance1
                Database           = $newDbName
                SchemaVersionTable = $logTable
                Silent             = $true
                DeploymentMethod   = 'NoTransaction'
            }
            $results = & $workFolder\deploy.ps1 -Configuration $deploymentConfig
            $results.Successful | Should Be $true
            $results.Scripts.Name | Should Be ((Get-Item $v1scripts).Name | ForEach-Object {'1.0\' + $_})
            $results.SqlInstance | Should Be $script:instance1
            $results.Database | Should Be $newDbName
            $results.SourcePath | Should Be $workFolder
            $results.ConnectionType | Should Be 'SQLServer'
            $results.Configuration.SchemaVersionTable | Should Be $logTable
            $results.Error | Should BeNullOrEmpty
            $results.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $results.StartTime | Should Not BeNullOrEmpty
            $results.EndTime | Should Not BeNullOrEmpty
            $results.EndTime | Should -BeGreaterOrEqual $results.StartTime
            'Upgrade successful' | Should BeIn $results.DeploymentLog

            #Verifying objects
            $results = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $verificationScript
            $logTable | Should BeIn $results.name
            'a' | Should BeIn $results.name
            'b' | Should BeIn $results.name
            'c' | Should Not BeIn $results.name
            'd' | Should Not BeIn $results.name
        }
        It "should deploy with a set of parameters" {
            $results = & $workFolder\deploy.ps1 -SqlInstance $script:instance1 -Database $newDbName -SchemaVersionTable $logTable -OutputFile "$workFolder\log.txt" -Silent
            $results.Successful | Should Be $true
            $results.Scripts.Name | Should Be ((Get-Item $v1scripts).Name | ForEach-Object {'1.0\' + $_})
            $results.SqlInstance | Should Be $script:instance1
            $results.Database | Should Be $newDbName
            $results.SourcePath | Should Be $workFolder
            $results.ConnectionType | Should Be 'SQLServer'
            $results.Configuration.SchemaVersionTable | Should Be $logTable
            $results.Error | Should BeNullOrEmpty
            $results.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $results.StartTime | Should Not BeNullOrEmpty
            $results.EndTime | Should Not BeNullOrEmpty
            $results.EndTime | Should -BeGreaterOrEqual $results.StartTime
            'Upgrade successful' | Should BeIn $results.DeploymentLog

            #Verifying objects
            $results = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $verificationScript
            $logTable | Should BeIn $results.name
            'a' | Should BeIn $results.name
            'b' | Should BeIn $results.name
            'c' | Should Not BeIn $results.name
            'd' | Should Not BeIn $results.name
        }
    }
    Context  "$commandName whatif tests" {
        BeforeAll {
            $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $cleanupScript
        }
        AfterAll {
        }
        It "should deploy nothing" {
            $results = & $workFolder\deploy.ps1 -SqlInstance $script:instance1 -Database $newDbName -SchemaVersionTable $logTable -OutputFile "$workFolder\log.txt" -Silent -WhatIf
            $results.Successful | Should Be $true
            $results.Scripts.Name | Should Be ((Get-Item $v1scripts).Name | ForEach-Object {'1.0\' + $_})
            $results.SqlInstance | Should Be $script:instance1
            $results.Database | Should Be $newDbName
            $results.SourcePath | Should Be $workFolder
            $results.ConnectionType | Should Be 'SQLServer'
            $results.Configuration.SchemaVersionTable | Should Be $logTable
            $results.Error | Should BeNullOrEmpty
            $results.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $results.StartTime | Should Not BeNullOrEmpty
            $results.EndTime | Should Not BeNullOrEmpty
            $results.EndTime | Should -BeGreaterOrEqual $results.StartTime
            "No deployment performed - WhatIf mode." | Should BeIn $results.DeploymentLog
            ((Get-Item $v1scripts).Name | ForEach-Object { '1.0\' + $_ }) + " would have been executed - WhatIf mode." | Should BeIn $results.DeploymentLog

            #Verifying objects
            $results = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $verificationScript
            $logTable | Should Not BeIn $results.name
            'a' | Should Not BeIn $results.name
            'b' | Should Not BeIn $results.name
            'c' | Should Not BeIn $results.name
            'd' | Should Not BeIn $results.name
        }
    }
}
