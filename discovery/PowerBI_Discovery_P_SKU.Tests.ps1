BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot 'PowerBI_Discovery_P_SKU.ps1'
    . "$PSScriptRoot\Invoke-DiscoveryRequest.ps1"

    function New-TestFailure {
        param(
            [int] $StatusCode = 429,
            [string] $RetryAfter,
            [string] $Message = 'Too many requests',
            [switch] $LegacyHeaders
        )
        $response = [System.Net.Http.HttpResponseMessage]::new(
            [System.Net.HttpStatusCode]$StatusCode)
        if ($LegacyHeaders) {
            $headers = [System.Net.WebHeaderCollection]::new()
            if ($RetryAfter) { $headers['Retry-After'] = $RetryAfter }
            $response = [pscustomobject]@{ StatusCode = $StatusCode; Headers = $headers }
        } elseif ($RetryAfter) {
            $null = $response.Headers.TryAddWithoutValidation('Retry-After', $RetryAfter)
        }
        $exception = [Exception]::new($Message)
        $exception | Add-Member -NotePropertyName Response -NotePropertyValue $response
        return $exception
    }
}

Describe 'Discovery throttling retries' {
    BeforeEach {
        Mock Start-Sleep {}
        Mock Write-Warning {}
        Mock Get-Random { 0 }
        $script:calls = 0
    }

    It 'returns successful results without waiting' {
        $result = Invoke-DiscoveryRequest -Description 'Test' -Operation { 'one'; 'two' }
        $result | Should -HaveCount 2
        Should -Invoke Start-Sleep -Times 0
    }

    It 'honors Retry-After seconds with modern and legacy headers' -ForEach @(
        @{ Legacy = $false }, @{ Legacy = $true }
    ) {
        $script:failure = New-TestFailure -RetryAfter '42' -LegacyHeaders:$Legacy
        $result = Invoke-DiscoveryRequest -Description 'Test' -Operation {
            $script:calls++
            if ($script:calls -eq 1) { throw $script:failure }
            'recovered'
        }
        $result | Should -Be 'recovered'
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 42 }
    }

    It 'honors an HTTP-date Retry-After' {
        $date = [DateTimeOffset]::UtcNow.AddSeconds(120).ToString('r')
        $script:failure = New-TestFailure -RetryAfter $date
        Invoke-DiscoveryRequest -Description 'Test' -Operation {
            $script:calls++
            if ($script:calls -eq 1) { throw $script:failure }
        }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter {
            $Seconds -ge 110 -and $Seconds -le 121
        }
    }

    It 'uses the UTC unblock time for a RequestBlocked body without HTTP status' {
        $date = [DateTimeOffset]::UtcNow.AddSeconds(120).ToString(
            'M/d/yyyy h:mm:ss tt', [Globalization.CultureInfo]::InvariantCulture)
        $script:failure = [Exception]::new(
            '{"errorCode":"RequestBlocked","message":"Request is blocked by the upstream service until: ' +
            $date + ' (UTC)","isRetriable":true}')
        Invoke-DiscoveryRequest -Description 'Test' -Operation {
            $script:calls++
            if ($script:calls -eq 1) { throw $script:failure }
        }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter {
            $Seconds -ge 110 -and $Seconds -le 121
        }
    }

    It 'backs off without Retry-After and stops after the retry limit' {
        $script:failure = New-TestFailure
        {
            Invoke-DiscoveryRequest -Description 'Test' -MaxRetries 2 -Operation {
                $script:calls++
                'partial output'
                throw $script:failure
            }
        } | Should -Throw '*Too many requests*'
        $script:calls | Should -Be 3
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 2 }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 4 }
    }

    It 'does not duplicate output from failed attempts' {
        $script:failure = New-TestFailure -RetryAfter '0'
        $result = @(Invoke-DiscoveryRequest -Description 'Test' -Operation {
            $script:calls++
            'one'
            if ($script:calls -eq 1) { throw $script:failure }
            'two'
        })
        $result | Should -HaveCount 2
        $result[0] | Should -Be 'one'
        $result[1] | Should -Be 'two'
    }

    It 'honors dictionary headers returned by Power BI clients' {
        $script:failure = [Exception]::new('Too many requests')
        $script:failure | Add-Member -NotePropertyName Response -NotePropertyValue (
            [pscustomobject]@{
                StatusCode = 429
                Headers = @{ 'Retry-After' = @('25') }
            }
        )
        Invoke-DiscoveryRequest -Description 'Test' -Operation {
            $script:calls++
            if ($script:calls -eq 1) { throw $script:failure }
        }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 25 }
    }

    It 'does not retry permission errors' {
        $script:failure = New-TestFailure -StatusCode 403 -Message 'Forbidden'
        {
            Invoke-DiscoveryRequest -Description 'Test' -Operation { throw $script:failure }
        } | Should -Throw '*Forbidden*'
        Should -Invoke Start-Sleep -Times 0
    }
}

Describe 'Discovery export after throttling' {
    BeforeAll {
        # Local stubs allow mocking without installing the Power BI module.
        function Connect-PowerBIServiceAccount {}
        function Get-PowerBIWorkspace { [CmdletBinding()] param($Scope, [switch]$All, $Filter, $Id) }
        function Get-PowerBIAccessToken { [CmdletBinding()] param() }
        function Get-PowerBIDashboard { [CmdletBinding()] param($WorkspaceId) }
        function Get-PowerBIReport { [CmdletBinding()] param($WorkspaceId) }
        function Get-PowerBIDataset { [CmdletBinding()] param($WorkspaceId) }
        function Get-PowerBIDataflow { [CmdletBinding()] param($WorkspaceId) }
    }

    BeforeEach {
        $script:exported = @()
        $script:datasetCalls = 0
        $script:failure = New-TestFailure -RetryAfter '10'
        Mock Connect-PowerBIServiceAccount {}
        Mock Get-PowerBIWorkspace {
            [pscustomobject]@{ ID = 'workspace-1'; Name = 'Test workspace'; Users = @() }
        }
        Mock Get-PowerBIAccessToken { @{ Authorization = 'Bearer test-token' } }
        Mock Get-PowerBIDashboard {}
        Mock Get-PowerBIReport {}
        Mock Get-PowerBIDataset { [pscustomobject]@{ Name = 'Test model'; SizeInBytes = 1GB } }
        Mock Get-PowerBIDataflow {}
        Mock Invoke-RestMethod { [pscustomobject]@{ itemEntities = @() } }
        Mock Start-Sleep {}
        Mock Write-Warning {}
        Mock Write-Host {}
        Mock Set-Content {}
        Mock Export-Csv { $script:exported += $InputObject }
    }

    It 'preserves the workspace and exports an unknown count after exhausted retries' {
        Mock Invoke-RestMethod { throw $script:failure }
        . $scriptPath
        $script:exported | Should -HaveCount 1
        $script:exported[0].WorkspaceName | Should -Be 'Test workspace'
        $script:exported[0].FabricItemsCount | Should -BeNullOrEmpty
        $script:exported[0].DatasetsCount | Should -Be 1
        Should -Invoke Invoke-RestMethod -Times 6 -Exactly
        Should -Invoke Start-Sleep -Times 5 -Exactly
        Should -Invoke Write-Host -Times 1 -ParameterFilter {
            $Object -like 'Error verifying Fabric Items*'
        }
    }

    It 'exports recovered counts after a non-terminating Power BI throttle and a Fabric throttle' {
        Mock Get-PowerBIDataset {
            $script:datasetCalls++
            if ($script:datasetCalls -eq 1) {
                Write-Error -Exception $script:failure
                return
            }
            [pscustomobject]@{ Name = 'Test model'; SizeInBytes = 1GB }
        }
        $script:fabricCalls = 0
        Mock Invoke-RestMethod {
            $script:fabricCalls++
            if ($script:fabricCalls -eq 1) { throw $script:failure }
            [pscustomobject]@{ itemEntities = @([pscustomobject]@{ type = 'Lakehouse' }) }
        }
        . $scriptPath
        $script:exported | Should -HaveCount 1
        $script:exported[0].FabricItemsCount | Should -Be 1
        $script:exported[0].DatasetsCount | Should -Be 1
        $script:exported[0].LargeModelCount | Should -Be 1
        Should -Invoke Get-PowerBIDataset -Times 2 -Exactly
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly
    }

    It 'keeps a genuine zero count when the Fabric request succeeds with no items' {
        . $scriptPath
        $script:exported[0].FabricItemsCount | Should -Be 0
        Should -Invoke Start-Sleep -Times 0
    }

    It 'retries the tranche Fabric call and keeps rows with unknown counts if retries run out' {
        Mock Import-Csv { [pscustomobject]@{ WorkspaceId = 'workspace-1' } }
        $script:fabricCalls = 0
        Mock Invoke-RestMethod {
            $script:fabricCalls++
            if ($script:fabricCalls -ne 2) { throw $script:failure }
            [pscustomobject]@{ itemEntities = @([pscustomobject]@{ type = 'Lakehouse' }) }
        }
        $tranchesPath = Join-Path $PSScriptRoot 'DiscoveryScriptWSTranches.ps1'
        . $tranchesPath
        . $tranchesPath
        $script:exported | Should -HaveCount 2
        $script:exported[0].FabricItemsCount | Should -Be 1
        $script:exported[1].FabricItemsCount | Should -BeNullOrEmpty
        Should -Invoke Start-Sleep -Times 6 -Exactly -ParameterFilter { $Seconds -eq 10 }
    }

    It 'keeps the active dedicated-capacity filter by default' {
        . $scriptPath
        Should -Invoke Get-PowerBIWorkspace -Times 1 -Exactly -ParameterFilter {
            $Scope -eq 'Organization' -and $All -and
                $Filter -eq "isOnDedicatedCapacity eq true and tolower(state) eq 'active'"
        }
    }

    It 'exports active shared and dedicated workspaces, but not personal workspaces, when requested' {
        Mock Get-PowerBIWorkspace {
            [pscustomobject]@{ ID = 'shared'; Type = 'Workspace'; IsOnDedicatedCapacity = $false }
            [pscustomobject]@{ ID = 'dedicated'; Type = 'Workspace'; IsOnDedicatedCapacity = $true }
            [pscustomobject]@{ ID = 'personal'; Type = 'PersonalGroup'; IsOnDedicatedCapacity = $false }
        }
        . $scriptPath -IncludeSharedCapacity
        $script:exported | Should -HaveCount 2
        $script:exported.WorkspaceId | Should -Contain 'shared'
        $script:exported.WorkspaceId | Should -Contain 'dedicated'
        Should -Invoke Set-Content -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -like '*\XXXXWorkspacesT1.csv' -and
                ($Value -join ',') -eq 'WorkspaceId,shared,dedicated'
        }
        Should -Invoke Get-PowerBIWorkspace -Times 1 -Exactly -ParameterFilter {
            $Scope -eq 'Organization' -and $All -and $Filter -eq "tolower(state) eq 'active'"
        }
    }
}
