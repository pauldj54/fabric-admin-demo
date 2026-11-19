BeforeAll {
    $exportScript = Join-Path $PSScriptRoot 'Export-SemanticModelSizes.ps1'
    function Connect-PowerBIServiceAccount { [CmdletBinding()] param() }
    function Get-PowerBIWorkspace { [CmdletBinding()] param($Scope, $Id, $Include) }
    function Get-PowerBIAccessToken { [CmdletBinding()] param([switch]$AsString) }
    function Invoke-ASCmd { [CmdletBinding()] param($ConnectionString, $Query, $QueryTimeout, $ConnectionTimeout) }
}

Describe 'Semantic model size CSV presentation' {
    BeforeEach {
        Mock Import-Module {}
        Mock Test-Path { $true }
        Mock Import-Csv { [pscustomobject]@{ WorkspaceId = '00000000-0000-0000-0000-000000000001' } }
        Mock Connect-PowerBIServiceAccount {}
        Mock Get-PowerBIAccessToken { 'Bearer test-token' }
        Mock Get-PowerBIWorkspace {
            [pscustomobject]@{
                Id = [guid]'00000000-0000-0000-0000-000000000001'
                Name = 'Sales; Europe'
                Type = 'Workspace'
                State = 'Active'
                Datasets = @(
                    [pscustomobject]@{ Id = 'measured'; Name = 'Import model' }
                    [pscustomobject]@{ Id = 'failed'; Name = 'Denied model' }
                )
            }
        }
        Mock Invoke-ASCmd {
            $builder = [System.Data.Common.DbConnectionStringBuilder]::new()
            $builder.set_ConnectionString($ConnectionString)
            if ($builder['Initial Catalog'] -eq 'Denied model') {
                throw "Permission denied`nTechnical Details:`nRootActivityId: test"
            }
            if ($Query -match 'DICTIONARY_SIZE') {
                '<root><row><value>1107757</value></row></root>'
            } else {
                '<root><row><value>0</value></row></root>'
            }
        }
        Mock Write-Host {}
        Mock Write-Warning {}
    }

    It 'writes only a header and data records without technical details' -ForEach @(
        @{ Separator = ';' }, @{ Separator = ',' }
    ) {
        $output = Join-Path $TestDrive 'sizes.csv'
        . $exportScript -OutputPath $output -Delimiter $Separator
        $lines = [IO.File]::ReadAllLines($output)
        $lines | Should -HaveCount 3
        ($lines -join "`n") | Should -Not -Match 'Details|RootActivityId|Permission denied'
        $records = @($lines | ConvertFrom-Csv -Delimiter $Separator)
        $records | Should -HaveCount 2
        $records[0].WorkspaceName | Should -Be 'Sales; Europe'
        $records[0].EstimatedVertiPaqBytes | Should -Be '1107757'
        $records[1].EstimatedVertiPaqBytes | Should -BeNullOrEmpty
        $records[1].SizeStatus | Should -Be 'Unavailable'
        Should -Invoke Write-Warning -Times 1
    }

    It 'writes a header only when there are no models' {
        Mock Get-PowerBIWorkspace {
            [pscustomobject]@{
                Id = [guid]'00000000-0000-0000-0000-000000000001'
                Name = 'Empty'
                Type = 'Workspace'
                State = 'Active'
                Datasets = @()
            }
        }
        $output = Join-Path $TestDrive 'empty.csv'
        . $exportScript -OutputPath $output
        $lines = [IO.File]::ReadAllLines($output)
        $lines | Should -HaveCount 1
        $lines[0] | Should -Be 'WorkspaceId;WorkspaceName;SemanticModelId;SemanticModelName;PartitionModes;EstimatedVertiPaqBytes;SizeStatus'
    }
}
