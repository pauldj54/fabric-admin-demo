function Invoke-DiscoveryRequest {
    param(
        [Parameter(Mandatory)]
        [scriptblock] $Operation,
        [Parameter(Mandatory)]
        [string] $Description,
        [ValidateRange(0, 10)]
        [int] $MaxRetries = 5
    )

    for ($attempt = 0; ; $attempt++) {
        try {
            # Buffer results so a failed attempt cannot leak partial output.
            $result = & $Operation
            return $result
        } catch {
            $failure = $_
            $response = $failure.Exception.Response
            $statusCode = $response.StatusCode
            if ($null -eq $statusCode) {
                $statusCode = $failure.Exception.StatusCode
            }

            $message = $failure.ErrorDetails.Message
            if ([string]::IsNullOrWhiteSpace($message)) {
                $message = $failure.Exception.Message
            }
            $isThrottled = ($null -ne $statusCode -and [int]$statusCode -eq 429) -or
                $message -match '"errorCode"\s*:\s*"RequestBlocked"'
            if (-not $isThrottled -or $attempt -ge $MaxRetries) {
                throw
            }

            $delay = [math]::Pow(2, $attempt + 1) + (Get-Random -Minimum 0 -Maximum 4)
            $retryAfter = $null
            if ($null -ne $response.Headers) {
                # REST calls and Power BI cmdlets expose different header types.
                if ($response.Headers -is [System.Net.Http.Headers.HttpHeaders]) {
                    if ($response.Headers.Contains('Retry-After')) {
                        $retryAfter = @($response.Headers.GetValues('Retry-After'))[0]
                    }
                } elseif ($response.Headers -is [System.Collections.Specialized.NameValueCollection]) {
                    $retryAfter = @($response.Headers.GetValues('Retry-After'))[0]
                } else {
                    $retryAfter = @($response.Headers['Retry-After'])[0]
                }
            }

            $seconds = 0
            $retryDate = [DateTimeOffset]::MinValue
            $dateStyle = [Globalization.DateTimeStyles]::AssumeUniversal
            $culture = [Globalization.CultureInfo]::InvariantCulture
            if ([int]::TryParse($retryAfter, [ref]$seconds) -and $seconds -ge 0) {
                $delay = $seconds
            } elseif ([DateTimeOffset]::TryParse($retryAfter, $culture, $dateStyle, [ref]$retryDate)) {
                $delay = [math]::Max(1, [math]::Ceiling(($retryDate - [DateTimeOffset]::UtcNow).TotalSeconds))
            } elseif ($message -match 'blocked by the upstream service until:\s*(.+?)\s*\(UTC\)' -and
                [DateTimeOffset]::TryParse($Matches[1], $culture, $dateStyle, [ref]$retryDate)) {
                $delay = [math]::Max(1, [math]::Ceiling(($retryDate - [DateTimeOffset]::UtcNow).TotalSeconds))
            }

            Write-Warning "$Description throttled. Retrying in $delay seconds (retry $($attempt + 1)/$MaxRetries)."
            Start-Sleep -Seconds $delay
        }
    }
}
