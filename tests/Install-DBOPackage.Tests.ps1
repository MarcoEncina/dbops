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
$tranFailScripts = "$here\etc\install-tests\transactional-failure"
$v1scripts = "$here\etc\install-tests\success\1.sql"
$v2scripts = "$here\etc\install-tests\success\2.sql"
$verificationScript = "$here\etc\install-tests\verification\select.sql"
$packageName = Join-Path $workFolder "TempDeployment.zip"
$packageNamev1 = Join-Path $workFolder "TempDeployment_v1.zip"
$fullConfig = "$here\etc\tmp_full_config.json"
$fullConfigSource = "$here\etc\full_config.json"
$testPassword = 'TestPassword'
$encryptedString = $testPassword | ConvertTo-SecureString -Force -AsPlainText | ConvertTo-EncryptedString
$newDbName = "_test_$commandName"

Describe "Install-DBOPackage integration tests" -Tag $commandName, IntegrationTests {
    BeforeAll {
        if ((Test-Path $workFolder) -and $workFolder -like '*.Tests.dbops') { Remove-Item $workFolder -Recurse }
        $null = New-Item $workFolder -ItemType Directory -Force
        $null = New-Item $unpackedFolder -ItemType Directory -Force
        (Get-Content $fullConfigSource -Raw) -replace 'replaceMe', $encryptedString | Out-File $fullConfig -Force
        $dropDatabaseScript = 'IF EXISTS (SELECT * FROM sys.databases WHERE name = ''{0}'') BEGIN ALTER DATABASE [{0}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [{0}]; END' -f $newDbName
        $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database master -Query $dropDatabaseScript
    }
    AfterAll {
        if ((Test-Path $workFolder) -and $workFolder -like '*.Tests.dbops') { Remove-Item $workFolder -Recurse }
        if (Test-Path $fullConfig) { Remove-Item $fullConfig }
        $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database master -Query $dropDatabaseScript
    }
    Context "testing regular deployment with CreateDatabase specified" {
        BeforeAll {
            $p1 = New-DBOPackage -ScriptPath $v1scripts -Name "$workFolder\pv1" -Build 1.0 -Force
        }
        It "should deploy version 1.0 to a new database using -CreateDatabase switch" {
            $results = Install-DBOPackage $p1 -CreateDatabase -SqlInstance $script:instance1 -Database $newDbName -SchemaVersionTable $logTable -OutputFile "$workFolder\log.txt" -Silent
            $results.Successful | Should Be $true
            $results.Scripts.Name | Should Be ((Get-Item $v1scripts).Name | ForEach-Object {'1.0\' + $_})
            $results.SqlInstance | Should Be $script:instance1
            $results.Database | Should Be $newDbName
            $results.SourcePath | Should Be "$workFolder\pv1.zip"
            $results.ConnectionType | Should Be 'SQLServer'
            $results.Configuration.SchemaVersionTable | Should Be $logTable
            $results.Configuration.CreateDatabase | Should Be $true
            $results.Error | Should BeNullOrEmpty
            $results.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $results.StartTime | Should Not BeNullOrEmpty
            $results.EndTime | Should Not BeNullOrEmpty
            $results.EndTime | Should -BeGreaterOrEqual $results.StartTime
            'Upgrade successful' | Should BeIn $results.DeploymentLog
            "Created database $newDbName" | Should BeIn $results.DeploymentLog

            #Verifying objects
            $results = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $verificationScript
            $logTable | Should BeIn $results.name
            'a' | Should BeIn $results.name
            'b' | Should BeIn $results.name
            'c' | Should Not BeIn $results.name
            'd' | Should Not BeIn $results.name
        }
    }
    Context "testing transactional deployment" {
        BeforeAll {
            $null = New-DBOPackage -ScriptPath $tranFailScripts -Name $packageName -Build 1.0 -Force
        }
        AfterAll {
            $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $cleanupScript
        }
        BeforeEach {
            $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $cleanupScript
        }
        It "Should throw an error and not create any objects" {
            #Running package
            try {
                $null = Install-DBOPackage $packageName -SqlInstance $script:instance1 -Database $newDbName -SchemaVersionTable $logTable -DeploymentMethod SingleTransaction -Silent
            }
            catch {
                $results = $_
            }
            $results.Exception.Message | Should Be "There is already an object named 'a' in the database."
            #Verifying objects
            $results = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $verificationScript
            $logTable | Should Not BeIn $results.name
            'a' | Should Not BeIn $results.name
            'b' | Should Not BeIn $results.name
            'c' | Should Not BeIn $results.name
            'd' | Should Not BeIn $results.name
        }

    }
    Context "testing non transactional deployment" {
        BeforeAll {
            $null = New-DBOPackage -ScriptPath $tranFailScripts -Name $packageName -Build 1.0 -Force
        }
        AfterAll {
            $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $cleanupScript
        }
        It "Should throw an error and create one object" {
            #Running package
            try {
                $null = Install-DBOPackage $packageName -SqlInstance $script:instance1 -Database $newDbName -SchemaVersionTable $logTable -DeploymentMethod NoTransaction -Silent
            }
            catch {
                $results = $_
            }
            $results.Exception.Message | Should Be "There is already an object named 'a' in the database."
            #Verifying objects
            $results = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $verificationScript
            $logTable | Should BeIn $results.name
            'a' | Should BeIn $results.name
            'b' | Should Not BeIn $results.name
            'c' | Should Not BeIn $results.name
            'd' | Should Not BeIn $results.name
        }
    }
    Context "testing regular deployment" {
        BeforeAll {
            $p1 = New-DBOPackage -ScriptPath $v1scripts -Name "$workFolder\pv1" -Build 1.0 -Force
            $p1 = Add-DBOBuild -ScriptPath $v2scripts -Name $p1 -Build 2.0
            #versions should not be sorted by default - creating a package where 1.0 is the second build
            $p3 = New-DBOPackage -ScriptPath $v1scripts -Name "$workFolder\pv3" -Build 2.0 -Force
            $null = Add-DBOBuild -ScriptPath $v2scripts -Name $p3 -Build 1.0
            $outputFile = "$workFolder\log.txt"
            $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $cleanupScript
        }
        It "should deploy version 1.0" {
            $results = Install-DBOPackage $p1 -Build '1.0' -SqlInstance $script:instance1 -Database $newDbName -SchemaVersionTable $logTable -OutputFile "$workFolder\log.txt" -Silent
            $results.Successful | Should Be $true
            $results.Scripts.Name | Should Be ((Get-Item $v1scripts).Name | ForEach-Object {'1.0\' + $_})
            $results.SqlInstance | Should Be $script:instance1
            $results.Database | Should Be $newDbName
            $results.SourcePath | Should Be "$workFolder\pv1.zip"
            $results.ConnectionType | Should Be 'SQLServer'
            $results.Configuration.SchemaVersionTable | Should Be $logTable
            $results.Error | Should BeNullOrEmpty
            $results.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $results.StartTime | Should Not BeNullOrEmpty
            $results.EndTime | Should Not BeNullOrEmpty
            $results.EndTime | Should -BeGreaterOrEqual $results.StartTime
            'Upgrade successful' | Should BeIn $results.DeploymentLog

            $output = Get-Content "$workFolder\log.txt" | Select-Object -Skip 1
            $output | Should Be (Get-Content "$here\etc\log1.txt")
            #Verifying objects
            $results = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $verificationScript
            $logTable | Should BeIn $results.name
            'a' | Should BeIn $results.name
            'b' | Should BeIn $results.name
            'c' | Should Not BeIn $results.name
            'd' | Should Not BeIn $results.name
        }
        It "should re-deploy version 1.0 pipelining a string" {
            $results = "$workFolder\pv1.zip" | Install-DBOPackage -Build '1.0' -SqlInstance $script:instance1 -Database $newDbName -SchemaVersionTable $logTable -OutputFile "$workFolder\log.txt" -Silent
            $results.Successful | Should Be $true
            $results.Scripts.Name | Should BeNullOrEmpty
            $results.SqlInstance | Should Be $script:instance1
            $results.Database | Should Be $newDbName
            $results.SourcePath | Should Be "$workFolder\pv1.zip"
            $results.ConnectionType | Should Be 'SQLServer'
            $results.Configuration.SchemaVersionTable | Should Be $logTable
            $results.Error | Should BeNullOrEmpty
            $results.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $results.StartTime | Should Not BeNullOrEmpty
            $results.EndTime | Should Not BeNullOrEmpty
            $results.EndTime | Should -BeGreaterOrEqual $results.StartTime
            'No new scripts need to be executed - completing.' | Should BeIn $results.DeploymentLog

            'No new scripts need to be executed - completing.' | Should BeIn (Get-Content "$workFolder\log.txt" | Select-Object -Skip 1)
            #Verifying objects
            $results = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $verificationScript
            $logTable | Should BeIn $results.name
            'a' | Should BeIn $results.name
            'b' | Should BeIn $results.name
            'c' | Should Not BeIn $results.name
            'd' | Should Not BeIn $results.name
        }
        It "should deploy version 2.0 using pipelined Get-DBOPackage" {
            $results = Get-DBOPackage "$workFolder\pv1.zip" | Install-DBOPackage -Build '1.0','2.0' -SqlInstance $script:instance1 -Database $newDbName -SchemaVersionTable $logTable -OutputFile "$workFolder\log.txt" -Silent
            $results.Successful | Should Be $true
            $results.Scripts.Name | Should Be ((Get-Item $v2scripts).Name | ForEach-Object { '2.0\' + $_ })
            $results.SqlInstance | Should Be $script:instance1
            $results.Database | Should Be $newDbName
            $results.SourcePath | Should Be "$workFolder\pv1.zip"
            $results.ConnectionType | Should Be 'SQLServer'
            $results.Configuration.SchemaVersionTable | Should Be $logTable
            $results.Error | Should BeNullOrEmpty
            $results.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $results.StartTime | Should Not BeNullOrEmpty
            $results.EndTime | Should Not BeNullOrEmpty
            $results.EndTime | Should -BeGreaterOrEqual $results.StartTime
            'Upgrade successful' | Should BeIn $results.DeploymentLog

            $output = Get-Content "$workFolder\log.txt" | Select-Object -Skip 1
            $output | Should Be (Get-Content "$here\etc\log2.txt")
            #Verifying objects
            $results = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $verificationScript
            $logTable | Should BeIn $results.name
            'a' | Should BeIn $results.name
            'b' | Should BeIn $results.name
            'c' | Should BeIn $results.name
            'd' | Should BeIn $results.name
        }
        It "should re-deploy version 2.0 using pipelined FileSystemObject" {
            $results = Get-Item "$workFolder\pv1.zip" | Install-DBOPackage -SqlInstance $script:instance1 -Database $newDbName -SchemaVersionTable $logTable -OutputFile "$workFolder\log.txt" -Silent
            $results.Successful | Should Be $true
            $results.Scripts.Name | Should BeNullOrEmpty
            $results.SqlInstance | Should Be $script:instance1
            $results.Database | Should Be $newDbName
            $results.SourcePath | Should Be "$workFolder\pv1.zip"
            $results.ConnectionType | Should Be 'SQLServer'
            $results.Configuration.SchemaVersionTable | Should Be $logTable
            $results.Error | Should BeNullOrEmpty
            $results.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $results.StartTime | Should Not BeNullOrEmpty
            $results.EndTime | Should Not BeNullOrEmpty
            $results.EndTime | Should -BeGreaterOrEqual $results.StartTime
            'No new scripts need to be executed - completing.' | Should BeIn $results.DeploymentLog

            'No new scripts need to be executed - completing.' | Should BeIn (Get-Content "$workFolder\log.txt" | Select-Object -Skip 1)
            #Verifying objects
            $results = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $verificationScript
            $logTable | Should BeIn $results.name
            'a' | Should BeIn $results.name
            'b' | Should BeIn $results.name
            'c' | Should BeIn $results.name
            'd' | Should BeIn $results.name
        }
        It "should deploy in a reversed order: 2.0 before 1.0" {
            $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $cleanupScript
            $results = Install-DBOPackage "$workFolder\pv3.zip" -SqlInstance $script:instance1 -Database $newDbName -SchemaVersionTable $logTable -OutputFile "$workFolder\log.txt" -Silent
            $results.Successful | Should Be $true
            $results.Scripts.Name | Should Be (@((Get-Item $v1scripts).Name | ForEach-Object { '2.0\' + $_ }), ((Get-Item $v2scripts).Name | ForEach-Object { '1.0\' + $_ }))
            $results.SqlInstance | Should Be $script:instance1
            $results.Database | Should Be $newDbName
            $results.SourcePath | Should Be "$workFolder\pv3.zip"
            $results.ConnectionType | Should Be 'SQLServer'
            $results.Configuration.SchemaVersionTable | Should Be $logTable
            $results.Error | Should BeNullOrEmpty
            $results.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $results.StartTime | Should Not BeNullOrEmpty
            $results.EndTime | Should Not BeNullOrEmpty
            $results.EndTime | Should -BeGreaterOrEqual $results.StartTime
            'Upgrade successful' | Should BeIn $results.DeploymentLog

            $results = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $verificationScript
            $logTable | Should BeIn $results.name
            'a' | Should BeIn $results.name
            'b' | Should BeIn $results.name
            'c' | Should BeIn $results.name
            'd' | Should BeIn $results.name
        }
    }
    Context "testing timeouts" {
        BeforeAll {
            $file = "$workFolder\delay.sql"
            "WAITFOR DELAY '00:00:03'; PRINT ('Successful!')" | Out-File $file
            $null = New-DBOPackage -ScriptPath $file -Name "$workFolder\delay" -Build 1.0 -Force -Configuration @{ ExecutionTimeout = 2 }
        }
        BeforeEach {
            $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $cleanupScript
        }
        It "should throw timeout error " {
            try {
                $null = Install-DBOPackage "$workFolder\delay.zip" -SqlInstance $script:instance1 -Database $newDbName -SchemaVersionTable $logTable -OutputFile "$workFolder\log.txt" -Silent
            }
            catch {
                $results = $_
            }
            $results | Should Not Be $null
            $results.Exception.Message | Should BeLike '*Timeout Expired.*'
            $output = Get-Content "$workFolder\log.txt" -Raw
            $output | Should BeLike '*Timeout Expired*'
            $output | Should Not BeLike '*Successful!*'
        }
        It "should successfully run within specified timeout" {
            $results = Install-DBOPackage "$workFolder\delay.zip" -SqlInstance $script:instance1 -Database $newDbName -SchemaVersionTable $logTable -OutputFile "$workFolder\log.txt" -Silent -ExecutionTimeout 6
            $results.Successful | Should Be $true
            $results.Scripts.Name | Should Be '1.0\delay.sql'
            $results.SqlInstance | Should Be $script:instance1
            $results.Database | Should Be $newDbName
            $results.SourcePath | Should Be "$workFolder\delay.zip"
            $results.ConnectionType | Should Be 'SQLServer'
            $results.Configuration.SchemaVersionTable | Should Be $logTable
            $results.Error | Should BeNullOrEmpty
            $results.Duration.TotalMilliseconds | Should -BeGreaterThan 3000
            $results.StartTime | Should Not BeNullOrEmpty
            $results.EndTime | Should Not BeNullOrEmpty
            $results.EndTime | Should -BeGreaterThan $results.StartTime
            'Upgrade successful' | Should BeIn $results.DeploymentLog

            $output = Get-Content "$workFolder\log.txt" -Raw
            $output | Should Not BeLike '*Timeout Expired*'
            $output | Should BeLike '*Successful!*'
        }
        It "should successfully run with infinite timeout" {
            $results = Install-DBOPackage "$workFolder\delay.zip" -SqlInstance $script:instance1 -Database $newDbName -SchemaVersionTable $logTable -OutputFile "$workFolder\log.txt" -Silent -ExecutionTimeout 0
            $results.Successful | Should Be $true
            $results.Scripts.Name | Should Be '1.0\delay.sql'
            $results.SqlInstance | Should Be $script:instance1
            $results.Database | Should Be $newDbName
            $results.SourcePath | Should Be "$workFolder\delay.zip"
            $results.ConnectionType | Should Be 'SQLServer'
            $results.Configuration.SchemaVersionTable | Should Be $logTable
            $results.Error | Should BeNullOrEmpty
            $results.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $results.StartTime | Should Not BeNullOrEmpty
            $results.EndTime | Should Not BeNullOrEmpty
            $results.EndTime | Should -BeGreaterOrEqual $results.StartTime
            'Upgrade successful' | Should BeIn $results.DeploymentLog

            $output = Get-Content "$workFolder\log.txt" -Raw
            $output | Should Not BeLike '*Timeout Expired*'
            $output | Should BeLike '*Successful!*'
        }
    }
    Context  "$commandName whatif tests" {
        BeforeAll {
            $null = New-DBOPackage -ScriptPath $v1scripts -Name $packageNamev1 -Build 1.0
            $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $cleanupScript
        }
        AfterAll {
            $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $cleanupScript
            Remove-Item $packageNamev1
        }
        It "should deploy nothing" {
            $results = Install-DBOPackage $packageNamev1 -SqlInstance $script:instance1 -Database $newDbName -SchemaVersionTable $logTable -Silent -WhatIf
            $results.SqlInstance | Should Be $script:instance1
            $results.Database | Should Be $newDbName
            $results.Scripts.Name | Should Be ((Get-Item $v1scripts).Name | ForEach-Object { '1.0\' + $_ })
            $results.SourcePath | Should Be $packageNamev1
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
    Context "testing regular deployment with configuration overrides" {
        BeforeAll {
            $p1 = New-DBOPackage -ScriptPath $v1scripts -Name "$workFolder\pv1" -Build 1.0 -Force -ConfigurationFile $fullConfig
            $p2 = New-DBOPackage -ScriptPath $v2scripts -Name "$workFolder\pv2" -Build 2.0 -Force -Configuration @{
                SqlInstance        = 'nonexistingServer'
                Database           = 'nonexistingDB'
                SchemaVersionTable = 'nonexistingSchema.nonexistinTable'
                DeploymentMethod   = "SingleTransaction"
            }
            $outputFile = "$workFolder\log.txt"
            $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $cleanupScript
        }
        It "should deploy version 1.0 using -Configuration file override" {
            $configFile = "$workFolder\config.custom.json"
            @{
                SqlInstance        = $script:instance1
                Database           = $newDbName
                SchemaVersionTable = $logTable
                Silent             = $true
                DeploymentMethod   = 'NoTransaction'
            } | ConvertTo-Json -Depth 2 | Out-File $configFile -Force
            $results = Install-DBOPackage "$workFolder\pv1.zip" -Configuration $configFile -OutputFile "$workFolder\log.txt"
            $results.Successful | Should Be $true
            $results.Scripts.Name | Should Be ((Get-Item $v1scripts).Name | ForEach-Object {'1.0\' + $_})
            $results.SqlInstance | Should Be $script:instance1
            $results.Database | Should Be $newDbName
            $results.SourcePath | Should Be "$workFolder\pv1.zip"
            $results.ConnectionType | Should Be 'SQLServer'
            $results.Configuration.SchemaVersionTable | Should Be $logTable
            $results.Error | Should BeNullOrEmpty
            $results.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $results.StartTime | Should Not BeNullOrEmpty
            $results.EndTime | Should Not BeNullOrEmpty
            $results.EndTime | Should -BeGreaterOrEqual $results.StartTime
            'Upgrade successful' | Should BeIn $results.DeploymentLog

            $output = Get-Content "$workFolder\log.txt" | Select-Object -Skip 1
            $output | Should Be (Get-Content "$here\etc\log1.txt")
            #Verifying objects
            $results = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $verificationScript
            $logTable | Should BeIn $results.name
            'a' | Should BeIn $results.name
            'b' | Should BeIn $results.name
            'c' | Should Not BeIn $results.name
            'd' | Should Not BeIn $results.name
        }
        It "should deploy version 2.0 using -Configuration object override" {
            $results = Install-DBOPackage "$workFolder\pv2.zip" -Configuration @{
                SqlInstance        = $script:instance1
                Database           = $newDbName
                SchemaVersionTable = $logTable
                Silent             = $true
                DeploymentMethod   = 'NoTransaction'
            } -OutputFile "$workFolder\log.txt"
            $results.Successful | Should Be $true
            $results.Scripts.Name | Should Be ((Get-Item $v2scripts).Name | ForEach-Object { '2.0\' + $_ })
            $results.SqlInstance | Should Be $script:instance1
            $results.Database | Should Be $newDbName
            $results.SourcePath | Should Be "$workFolder\pv2.zip"
            $results.ConnectionType | Should Be 'SQLServer'
            $results.Configuration.SchemaVersionTable | Should Be $logTable
            $results.Error | Should BeNullOrEmpty
            $results.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $results.StartTime | Should Not BeNullOrEmpty
            $results.EndTime | Should Not BeNullOrEmpty
            $results.EndTime | Should -BeGreaterOrEqual $results.StartTime
            'Upgrade successful' | Should BeIn $results.DeploymentLog

            $output = Get-Content "$workFolder\log.txt" | Select-Object -Skip 1
            $output | Should Be (Get-Content "$here\etc\log2.txt")
            #Verifying objects
            $results = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $verificationScript
            $logTable | Should BeIn $results.name
            'a' | Should BeIn $results.name
            'b' | Should BeIn $results.name
            'c' | Should BeIn $results.name
            'd' | Should BeIn $results.name
        }
    }
    Context "testing deployment without specifying SchemaVersion table" {
        BeforeAll {
            $p1 = New-DBOPackage -ScriptPath $v1scripts -Name "$workFolder\pv1" -Build 1.0 -Force
            $p2 = New-DBOPackage -ScriptPath $v2scripts -Name "$workFolder\pv2" -Build 2.0 -Force
            $outputFile = "$workFolder\log.txt"
            $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $cleanupScript
        }
        AfterAll {
            $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -Query "IF OBJECT_ID('SchemaVersions') IS NOT NULL DROP TABLE SchemaVersions"
        }
        It "should deploy version 1.0" {
            $before = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $verificationScript
            $rowsBefore = ($before | Measure-Object).Count
            $results = Install-DBOPackage "$workFolder\pv1.zip" -SqlInstance $script:instance1 -Database $newDbName -Silent
            $results.Successful | Should Be $true
            $results.Scripts.Name | Should Be ((Get-Item $v1scripts).Name | ForEach-Object {'1.0\' + $_})
            $results.SqlInstance | Should Be $script:instance1
            $results.Database | Should Be $newDbName
            $results.SourcePath | Should Be "$workFolder\pv1.zip"
            $results.ConnectionType | Should Be 'SQLServer'
            $results.Configuration.SchemaVersionTable | Should Be 'SchemaVersions'
            $results.Error | Should BeNullOrEmpty
            $results.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $results.StartTime | Should Not BeNullOrEmpty
            $results.EndTime | Should Not BeNullOrEmpty
            $results.EndTime | Should -BeGreaterOrEqual $results.StartTime
            'Upgrade successful' | Should BeIn $results.DeploymentLog

            #Verifying objects
            $results = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $verificationScript
            'SchemaVersions' | Should BeIn $results.name
            'a' | Should BeIn $results.name
            'b' | Should BeIn $results.name
            'c' | Should Not BeIn $results.name
            'd' | Should Not BeIn $results.name
            ($results | Measure-Object).Count | Should Be ($rowsBefore + 3)
        }
        It "should deploy version 2.0" {
            $before = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $verificationScript
            $rowsBefore = ($before | Measure-Object).Count
            $results = Install-DBOPackage "$workFolder\pv2.zip" -SqlInstance $script:instance1 -Database $newDbName -Silent
            $results.Successful | Should Be $true
            $results.Scripts.Name | Should Be ((Get-Item $v2scripts).Name | ForEach-Object { '2.0\' + $_ })
            $results.SqlInstance | Should Be $script:instance1
            $results.Database | Should Be $newDbName
            $results.SourcePath | Should Be "$workFolder\pv2.zip"
            $results.ConnectionType | Should Be 'SQLServer'
            $results.Configuration.SchemaVersionTable | Should Be 'SchemaVersions'
            $results.Error | Should BeNullOrEmpty
            $results.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $results.StartTime | Should Not BeNullOrEmpty
            $results.EndTime | Should Not BeNullOrEmpty
            $results.EndTime | Should -BeGreaterOrEqual $results.StartTime
            'Upgrade successful' | Should BeIn $results.DeploymentLog

            #Verifying objects
            $results = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $verificationScript
            'SchemaVersions' | Should BeIn $results.name
            'a' | Should BeIn $results.name
            'b' | Should BeIn $results.name
            'c' | Should BeIn $results.name
            'd' | Should BeIn $results.name
            ($results | Measure-Object).Count | Should Be ($rowsBefore + 2)
        }
    }
    Context "testing deployment with no history`: SchemaVersion is null" {
        BeforeEach {
            $null = New-DBOPackage -ScriptPath $v1scripts -Name "$workFolder\pv1" -Build 1.0 -Force
            $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $cleanupScript
        }
        AfterEach {
            $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -Query "IF OBJECT_ID('SchemaVersions') IS NOT NULL DROP TABLE SchemaVersions"
        }
        It "should deploy version 1.0 without creating SchemaVersions" {
            $before = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $verificationScript
            $rowsBefore = ($before | Measure-Object).Count
            $results = Install-DBOPackage "$workFolder\pv1.zip" -SqlInstance $script:instance1 -Database $newDbName -Silent -SchemaVersionTable $null
            $results.Successful | Should Be $true
            $results.Scripts.Name | Should Be ((Get-Item $v1scripts).Name | ForEach-Object {'1.0\' + $_})
            $results.SqlInstance | Should Be $script:instance1
            $results.Database | Should Be $newDbName
            $results.SourcePath | Should Be "$workFolder\pv1.zip"
            $results.ConnectionType | Should Be 'SQLServer'
            $results.Configuration.SchemaVersionTable | Should BeNullOrEmpty
            $results.Error | Should BeNullOrEmpty
            $results.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $results.StartTime | Should Not BeNullOrEmpty
            $results.EndTime | Should Not BeNullOrEmpty
            $results.EndTime | Should -BeGreaterOrEqual $results.StartTime
            'Upgrade successful' | Should BeIn $results.DeploymentLog

            #Verifying objects
            $results = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $verificationScript
            'SchemaVersions' | Should Not BeIn $results.name
            'a' | Should BeIn $results.name
            'b' | Should BeIn $results.name
            'c' | Should Not BeIn $results.name
            'd' | Should Not BeIn $results.name
            ($results | Measure-Object).Count | Should Be ($rowsBefore + 2)
        }
    }
    Context "testing deployment with defined schema" {
        BeforeEach {
            $null = New-DBOPackage -ScriptPath $v1scripts -Name "$workFolder\pv1" -Build 1.0 -Force
            $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $cleanupScript
            $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -Query "CREATE SCHEMA testschema"
        }
        AfterEach {
            $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -Query "IF OBJECT_ID('SchemaVersions') IS NOT NULL DROP TABLE SchemaVersions"
        }
        It "should deploy version 1.0 into testschema" {
            $before = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $verificationScript
            $rowsBefore = ($before | Measure-Object).Count
            $results = Install-DBOPackage "$workFolder\pv1.zip" -SqlInstance $script:instance1 -Database $newDbName -Silent -Schema testschema
            $results.Successful | Should Be $true
            $results.Scripts.Name | Should Be ((Get-Item $v1scripts).Name | ForEach-Object {'1.0\' + $_})
            $results.SqlInstance | Should Be $script:instance1
            $results.Database | Should Be $newDbName
            $results.SourcePath | Should Be "$workFolder\pv1.zip"
            $results.ConnectionType | Should Be 'SQLServer'
            $results.Configuration.SchemaVersionTable | Should Be 'SchemaVersions'
            $results.Configuration.Schema | Should Be 'testschema'
            $results.Error | Should BeNullOrEmpty
            $results.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $results.StartTime | Should Not BeNullOrEmpty
            $results.EndTime | Should Not BeNullOrEmpty
            $results.EndTime | Should -BeGreaterOrEqual $results.StartTime
            'Upgrade successful' | Should BeIn $results.DeploymentLog

            #Verifying objects
            $results = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $verificationScript
            $results | Where-Object Name -eq 'SchemaVersions' | Select-Object -ExpandProperty schema | Should Be 'testschema'
            # disabling for SQL Server, but leaving for other rdbms in perspective
            # $results | Where-Object Name -eq 'a' | Select-Object -ExpandProperty schema | Should Be 'testschema'
            # $results | Where-Object Name -eq 'b' | Select-Object -ExpandProperty schema | Should Be 'testschema'
            ($results | Measure-Object).Count | Should Be ($rowsBefore + 3)
        }
    }
    Context "testing deployment using variables in config" {
        BeforeAll {
            $p1 = New-DBOPackage -ScriptPath $v1scripts -Name "$workFolder\pv1" -Build 1.0 -Force -Configuration @{SqlInstance = '#{srv}'; Database = '#{db}'}
            $outputFile = "$workFolder\log.txt"
            $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $cleanupScript
        }
        AfterAll {
            $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -Query "IF OBJECT_ID('SchemaVersions') IS NOT NULL DROP TABLE SchemaVersions"
        }
        It "should deploy version 1.0" {
            $before = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $verificationScript
            $rowsBefore = ($before | Measure-Object).Count
            $results = Install-DBOPackage "$workFolder\pv1.zip" -Variables @{srv = $script:instance1; db = $newDbName} -SchemaVersionTable $logTable -OutputFile "$workFolder\log.txt" -Silent
            $results.Successful | Should Be $true
            $results.Scripts.Name | Should Be ((Get-Item $v1scripts).Name | ForEach-Object {'1.0\' + $_})
            $results.SqlInstance | Should Be $script:instance1
            $results.Database | Should Be $newDbName
            $results.SourcePath | Should Be "$workFolder\pv1.zip"
            $results.ConnectionType | Should Be 'SQLServer'
            $results.Configuration.SchemaVersionTable | Should Be $logTable
            $results.Error | Should BeNullOrEmpty
            $results.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $results.StartTime | Should Not BeNullOrEmpty
            $results.EndTime | Should Not BeNullOrEmpty
            $results.EndTime | Should -BeGreaterOrEqual $results.StartTime
            'Upgrade successful' | Should BeIn $results.DeploymentLog

            $output = Get-Content "$workFolder\log.txt" | Select-Object -Skip 1
            $output | Should Be (Get-Content "$here\etc\log1.txt")
            #Verifying objects
            $results = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $verificationScript
            $logTable | Should BeIn $results.name
            'a' | Should BeIn $results.name
            'b' | Should BeIn $results.name
            ($results | Measure-Object).Count | Should Be ($rowsBefore + 3)
        }
    }
    Context "testing deployment with custom connection string" {
        BeforeAll {
            $p1 = New-DBOPackage -ScriptPath $v1scripts -Name "$workFolder\pv1" -Build 1.0 -Force
            $null = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $cleanupScript
        }
        It "should deploy version 1.0" {
            $connectionString = "Server=$script:instance1;Database=$newDbName;Trusted_Connection=True"
            $results = Install-DBOPackage "$workFolder\pv1.zip" -ConnectionString $connectionString -SqlInstance willBeIgnored -Database IgnoredAsWell -SchemaVersionTable $logTable -OutputFile "$workFolder\log.txt" -Silent
            $results.Successful | Should Be $true
            $results.Scripts.Name | Should Be ((Get-Item $v1scripts).Name | ForEach-Object {'1.0\' + $_})
            $results.SqlInstance | Should BeNullOrEmpty
            $results.Database | Should BeNullOrEmpty
            $results.SourcePath | Should Be "$workFolder\pv1.zip"
            $results.ConnectionType | Should Be 'SQLServer'
            $results.Configuration.SchemaVersionTable | Should Be $logTable
            $results.Error | Should BeNullOrEmpty
            $results.Duration.TotalMilliseconds | Should -BeGreaterOrEqual 0
            $results.StartTime | Should Not BeNullOrEmpty
            $results.EndTime | Should Not BeNullOrEmpty
            $results.EndTime | Should -BeGreaterOrEqual $results.StartTime
            'Upgrade successful' | Should BeIn $results.DeploymentLog

            $output = Get-Content "$workFolder\log.txt" | Select-Object -Skip 1
            $output | Should Be (Get-Content "$here\etc\log1.txt")
            #Verifying objects
            $results = Invoke-SqlCmd2 -ServerInstance $script:instance1 -Database $newDbName -InputFile $verificationScript
            $logTable | Should BeIn $results.name
            'a' | Should BeIn $results.name
            'b' | Should BeIn $results.name
            'c' | Should Not BeIn $results.name
            'd' | Should Not BeIn $results.name
        }
    }
}
