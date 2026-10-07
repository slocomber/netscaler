<#
.SYNOPSIS
Finds the NetScaler objects that expose a backend server.

.EXAMPLE
.\Get-NetScalerServerDependency.ps1 -ConfigPath .\sample-netscaler.conf -ServerName api-app-01

.EXAMPLE
.\Get-NetScalerServerDependency.ps1 -ConfigPath C:\Exports\ns.conf -ServerName api-app-01 -AsJson

.EXAMPLE
.\Get-NetScalerServerDependency.ps1 -ConfigPath C:\Exports\ns.conf -ServerName api-app-01 -AsObject

.EXAMPLE
.\Get-NetScalerServerDependency.ps1 -ConfigPath C:\Exports\ns.conf -ServerName api-app-01 -AsHtml > dependency-report.html
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ConfigPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ServerName,

    [switch]$AsJson,

    [switch]$AsObject,

    [switch]$AsHtml
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NetScalerOption {
    param(
        [Parameter(Mandatory)]
        [string]$Line,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $match = [regex]::Match($Line, "(?i)(?:^|\s)-$([regex]::Escape($Name))\s+(?:""([^""]*)""|'([^']*)'|(\S+))")
    if (-not $match.Success) {
        return $null
    }

    foreach ($index in 1..3) {
        if ($match.Groups[$index].Success) {
            return $match.Groups[$index].Value
        }
    }
}

function Get-UniqueSorted {
    param([object[]]$Items)

    @($Items | Where-Object { $null -ne $_ -and $_ -ne '' } | Sort-Object -Unique)
}

function ConvertTo-NetScalerReport {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Dependency,

        [Parameter(Mandatory)]
        [string]$SourceConfigPath
    )

    $report = [System.Collections.Generic.List[string]]::new()
    $report.Add('NetScaler server dependency report')
    $report.Add(('=' * 34))
    $report.Add("Config:  $SourceConfigPath")
    $report.Add("Server:  $($Dependency.Server.Name) ($($Dependency.Server.Address))")

    $report.Add('')
    $report.Add('Peer servers sharing a load-balancing vServer')
    $report.Add('------------------------------------------------')
    if ($Dependency.PeerServers.Count -eq 0) {
        $report.Add('  (none)')
    }
    foreach ($peerServer in $Dependency.PeerServers) {
        $report.Add("  $($peerServer.Name) ($($peerServer.Address)) via $($peerServer.Service) on $($peerServer.LoadBalancingVserver)")
    }

    $report.Add('')
    $report.Add('Services')
    $report.Add('--------')
    if ($Dependency.Services.Count -eq 0) {
        $report.Add('  (none)')
    }
    foreach ($service in $Dependency.Services) {
        $report.Add("  $($service.Name): $($service.Protocol)/$($service.Port)")
    }

    $report.Add('')
    $report.Add('Service groups')
    $report.Add('--------------')
    if ($Dependency.ServiceGroups.Count -eq 0) {
        $report.Add('  (none)')
    }
    foreach ($serviceGroup in $Dependency.ServiceGroups) {
        $port = if ($null -eq $serviceGroup.Port) { '' } else { ":$($serviceGroup.Port)" }
        $report.Add("  $($serviceGroup.Name)$port")
    }

    $report.Add('')
    $report.Add('Service-group SSL configuration')
    $report.Add('-------------------------------')
    if ($Dependency.ServiceGroupSslConfiguration.Count -eq 0) {
        $report.Add('  (none)')
    }
    foreach ($sslConfiguration in $Dependency.ServiceGroupSslConfiguration) {
        $report.Add("  $($sslConfiguration.Line)")
    }

    $report.Add('')
    $report.Add('Health monitors')
    $report.Add('---------------')
    if ($Dependency.Monitors.Count -eq 0) {
        $report.Add('  (none)')
    }
    foreach ($monitor in $Dependency.Monitors) {
        $report.Add("  $($monitor.Name) ($($monitor.Type))")
    }

    $report.Add('')
    $report.Add('Load-balancing vServers')
    $report.Add('------------------------')
    if ($Dependency.LoadBalancingVservers.Count -eq 0) {
        $report.Add('  (none)')
    }
    foreach ($vserver in $Dependency.LoadBalancingVservers) {
        $settings = @()
        if ($vserver.LoadMethod) {
            $settings += "method=$($vserver.LoadMethod)"
        }
        if ($vserver.Persistence) {
            $settings += "persistence=$($vserver.Persistence)"
        }
        $settingsText = if ($settings.Count -gt 0) { " [$($settings -join ', ')]" } else { '' }
        $report.Add("  $($vserver.Name): $($vserver.Protocol) $($vserver.Address):$($vserver.Port)$settingsText")
    }

    $report.Add('')
    $report.Add('Content-switching vServers')
    $report.Add('--------------------------')
    if ($Dependency.ContentSwitchingVservers.Count -eq 0) {
        $report.Add('  (none)')
    }
    foreach ($vserver in $Dependency.ContentSwitchingVservers) {
        $report.Add("  $($vserver.Name): $($vserver.Protocol) $($vserver.Address):$($vserver.Port)")
        $report.Add("    policy=$($vserver.Policy), action=$($vserver.Action), target=$($vserver.TargetLBVserver)")
    }

    $report.Add('')
    $report.Add('Certificate bindings')
    $report.Add('--------------------')
    if ($Dependency.Certificates.Count -eq 0) {
        $report.Add('  (none)')
    }
    foreach ($certificate in $Dependency.Certificates) {
        $report.Add("  $($certificate.Vserver): $($certificate.Certificate)")
    }

    $report.Add('')
    $report.Add('Relevant vServer bindings')
    $report.Add('-------------------------')
    if ($Dependency.VserverBindings.Count -eq 0) {
        $report.Add('  (none)')
    }
    foreach ($binding in $Dependency.VserverBindings) {
        $report.Add("  $binding")
    }

    $report.Add('')
    $report.Add('Related unprocessed configuration lines')
    $report.Add('---------------------------------------')
    if ($Dependency.UnprocessedRelevantLines.Count -eq 0) {
        $report.Add('  (none)')
    }
    foreach ($line in $Dependency.UnprocessedRelevantLines) {
        $report.Add("  $line")
    }

    $report -join [Environment]::NewLine
}

function ConvertTo-NetScalerHtmlReport {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Dependency,

        [Parameter(Mandatory)]
        [string]$SourceConfigPath
    )

    function ConvertTo-HtmlText {
        param([AllowNull()][object]$Value)

        [System.Net.WebUtility]::HtmlEncode([string]$Value)
    }

    function ConvertTo-HtmlRows {
        param(
            [Parameter(Mandatory)]
            [AllowEmptyCollection()]
            [object[]]$Items,

            [Parameter(Mandatory)]
            [scriptblock]$Row
        )

        if ($Items.Count -eq 0) {
            return '<tr><td colspan="2" class="empty">(none)</td></tr>'
        }

        ($Items | ForEach-Object -Process { & $Row $_ }) -join [Environment]::NewLine
    }

    $peerServerRows = ConvertTo-HtmlRows -Items @($Dependency.PeerServers) -Row {
        param($peerServer)
        "<tr><td>$(ConvertTo-HtmlText $peerServer.Name)</td><td>$(ConvertTo-HtmlText $peerServer.Address)</td><td>$(ConvertTo-HtmlText $peerServer.Service)</td><td>$(ConvertTo-HtmlText $peerServer.LoadBalancingVserver)</td></tr>"
    }
    $serviceRows = ConvertTo-HtmlRows -Items @($Dependency.Services) -Row {
        param($service)
        "<tr><td>$(ConvertTo-HtmlText $service.Name)</td><td>$(ConvertTo-HtmlText "$($service.Protocol)/$($service.Port)")</td></tr>"
    }
    $serviceGroupRows = ConvertTo-HtmlRows -Items @($Dependency.ServiceGroups) -Row {
        param($serviceGroup)
        $port = if ($null -eq $serviceGroup.Port) { '' } else { ":$($serviceGroup.Port)" }
        "<tr><td>$(ConvertTo-HtmlText $serviceGroup.Name)</td><td>$(ConvertTo-HtmlText $port)</td></tr>"
    }
    $serviceGroupSslRows = ConvertTo-HtmlRows -Items @($Dependency.ServiceGroupSslConfiguration) -Row {
        param($sslConfiguration)
        "<tr><td><code>$(ConvertTo-HtmlText $sslConfiguration.Line)</code></td></tr>"
    }
    $monitorRows = ConvertTo-HtmlRows -Items @($Dependency.Monitors) -Row {
        param($monitor)
        "<tr><td>$(ConvertTo-HtmlText $monitor.Name)</td><td>$(ConvertTo-HtmlText $monitor.Type)</td></tr>"
    }
    $lbVserverRows = ConvertTo-HtmlRows -Items @($Dependency.LoadBalancingVservers) -Row {
        param($vserver)
        $settings = @()
        if ($vserver.LoadMethod) { $settings += "method=$($vserver.LoadMethod)" }
        if ($vserver.Persistence) { $settings += "persistence=$($vserver.Persistence)" }
        $endpoint = "$($vserver.Protocol) $($vserver.Address):$($vserver.Port)"
        "<tr><td>$(ConvertTo-HtmlText $vserver.Name)</td><td>$(ConvertTo-HtmlText $endpoint)</td><td>$(ConvertTo-HtmlText ($settings -join ', '))</td></tr>"
    }
    $csVserverRows = ConvertTo-HtmlRows -Items @($Dependency.ContentSwitchingVservers) -Row {
        param($vserver)
        $endpoint = "$($vserver.Protocol) $($vserver.Address):$($vserver.Port)"
        $route = "policy=$($vserver.Policy), action=$($vserver.Action), target=$($vserver.TargetLBVserver)"
        "<tr><td>$(ConvertTo-HtmlText $vserver.Name)</td><td>$(ConvertTo-HtmlText $endpoint)</td><td>$(ConvertTo-HtmlText $route)</td></tr>"
    }
    $certificateRows = ConvertTo-HtmlRows -Items @($Dependency.Certificates) -Row {
        param($certificate)
        "<tr><td>$(ConvertTo-HtmlText $certificate.Vserver)</td><td>$(ConvertTo-HtmlText $certificate.Certificate)</td></tr>"
    }
    $bindingRows = ConvertTo-HtmlRows -Items @($Dependency.VserverBindings) -Row {
        param($binding)
        "<tr><td colspan=""2""><code>$(ConvertTo-HtmlText $binding)</code></td></tr>"
    }
    $unprocessedLineRows = ConvertTo-HtmlRows -Items @($Dependency.UnprocessedRelevantLines) -Row {
        param($line)
        "<tr><td><code>$(ConvertTo-HtmlText $line)</code></td></tr>"
    }

@"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>NetScaler dependency report: $(ConvertTo-HtmlText $Dependency.Server.Name)</title>
<style>
body { color: #1f2937; font-family: system-ui, sans-serif; line-height: 1.5; margin: 2rem auto; max-width: 72rem; padding: 0 1rem; }
h1 { margin-bottom: 0.25rem; } h2 { border-bottom: 1px solid #d1d5db; margin-top: 2rem; padding-bottom: 0.25rem; }
table { border-collapse: collapse; margin: 0.75rem 0; width: 100%; } th, td { border: 1px solid #d1d5db; padding: 0.5rem 0.75rem; text-align: left; vertical-align: top; }
th { background: #f3f4f6; } code { overflow-wrap: anywhere; } .empty { color: #6b7280; font-style: italic; } .metadata { color: #4b5563; }
</style>
</head>
<body>
<h1>NetScaler server dependency report</h1>
<p class="metadata">Config: <code>$(ConvertTo-HtmlText $SourceConfigPath)</code></p>
<h2>Server</h2>
<table><thead><tr><th>Name</th><th>Address</th></tr></thead><tbody>
<tr><td>$(ConvertTo-HtmlText $Dependency.Server.Name)</td><td>$(ConvertTo-HtmlText $Dependency.Server.Address)</td></tr>
</tbody></table>
<h2>Peer servers sharing a load-balancing vServer</h2>
<table><thead><tr><th>Name</th><th>Address</th><th>Service</th><th>Shared LB vServer</th></tr></thead><tbody>$peerServerRows</tbody></table>
<h2>Services</h2>
<table><thead><tr><th>Name</th><th>Protocol / port</th></tr></thead><tbody>$serviceRows</tbody></table>
<h2>Service groups</h2>
<table><thead><tr><th>Name</th><th>Member port</th></tr></thead><tbody>$serviceGroupRows</tbody></table>
<h2>Service-group SSL configuration</h2>
<table><thead><tr><th>Configuration line</th></tr></thead><tbody>$serviceGroupSslRows</tbody></table>
<h2>Health monitors</h2>
<table><thead><tr><th>Name</th><th>Type</th></tr></thead><tbody>$monitorRows</tbody></table>
<h2>Load-balancing vServers</h2>
<table><thead><tr><th>Name</th><th>VIP</th><th>Settings</th></tr></thead><tbody>$lbVserverRows</tbody></table>
<h2>Content-switching vServers</h2>
<table><thead><tr><th>Name</th><th>VIP</th><th>Route</th></tr></thead><tbody>$csVserverRows</tbody></table>
<h2>Certificate bindings</h2>
<table><thead><tr><th>vServer</th><th>Certificate</th></tr></thead><tbody>$certificateRows</tbody></table>
<h2>Relevant vServer bindings</h2>
<table><thead><tr><th>Binding</th></tr></thead><tbody>$bindingRows</tbody></table>
<h2>Related unprocessed configuration lines</h2>
<table><thead><tr><th>Configuration line</th></tr></thead><tbody>$unprocessedLineRows</tbody></table>
</body>
</html>
"@
}

$lines = @(Get-Content -LiteralPath $ConfigPath | Where-Object {
        $_.Trim() -and -not $_.TrimStart().StartsWith('#')
    })

$serverPattern = '^\s*add\s+server\s+(?<Name>\S+)\s+(?<Address>\S+)'
$allServers = foreach ($line in $lines) {
    $match = [regex]::Match($line, $serverPattern, 'IgnoreCase')
    if ($match.Success) {
        [pscustomobject]@{
            Name    = $match.Groups['Name'].Value
            Address = $match.Groups['Address'].Value
            Line    = $line
        }
    }
}

$server = @($allServers | Where-Object { $_.Name -ieq $ServerName })
if (@($server).Count -eq 0) {
    throw "Server '$ServerName' was not found in '$ConfigPath'."
}
$serverAddresses = @{}
foreach ($configuredServer in $allServers) {
    $serverAddresses[$configuredServer.Name] = $configuredServer.Address
}

$allServices = foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*add\s+service\s+(?<Name>\S+)\s+(?<Server>\S+)\s+(?<Protocol>\S+)\s+(?<Port>\d+)', 'IgnoreCase')
    if ($match.Success) {
        [pscustomobject]@{
            Name     = $match.Groups['Name'].Value
            Server   = $match.Groups['Server'].Value
            Protocol = $match.Groups['Protocol'].Value
            Port     = [int]$match.Groups['Port'].Value
            Line     = $line
        }
    }
}
$services = @($allServices | Where-Object { $_.Server -ieq $server[0].Name })

$allServiceGroupMembers = foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*bind\s+serviceGroup\s+(?<Group>\S+)\s+(?<Server>\S+)(?:\s+(?<Port>\d+))?', 'IgnoreCase')
    if ($match.Success) {
        [pscustomobject]@{
            Name = $match.Groups['Group'].Value
            Server = $match.Groups['Server'].Value
            Port = if ($match.Groups['Port'].Success) { [int]$match.Groups['Port'].Value } else { $null }
            Line = $line
        }
    }
}
$serviceGroupMembers = @($allServiceGroupMembers | Where-Object { $_.Server -ieq $server[0].Name })

$serviceNames = Get-UniqueSorted @($services | ForEach-Object { $_.Name })
$serviceGroupNames = Get-UniqueSorted @($serviceGroupMembers | ForEach-Object { $_.Name })

$serviceGroupSslConfiguration = foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*(?:add\s+serviceGroup|set\s+ssl\s+serviceGroup|bind\s+ssl\s+serviceGroup)\s+(?<Group>\S+)', 'IgnoreCase')
    if ($match.Success -and $match.Groups['Group'].Value -in $serviceGroupNames) {
        [pscustomobject]@{
            ServiceGroup = $match.Groups['Group'].Value
            Line         = $line
        }
    }
}

$monitorNames = @(
    foreach ($line in $lines) {
        $match = [regex]::Match($line, '^\s*bind\s+service\s+(?<Service>\S+)\s+-monitorName\s+(?<Monitor>\S+)', 'IgnoreCase')
        if ($match.Success -and $match.Groups['Service'].Value -in $serviceNames) {
            $match.Groups['Monitor'].Value
        }

        $match = [regex]::Match($line, '^\s*bind\s+serviceGroup\s+(?<Group>\S+)\s+-monitorName\s+(?<Monitor>\S+)', 'IgnoreCase')
        if ($match.Success -and $match.Groups['Group'].Value -in $serviceGroupNames) {
            $match.Groups['Monitor'].Value
        }
    }
) | Sort-Object -Unique

$monitors = foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*add\s+lb\s+monitor\s+(?<Name>\S+)\s+(?<Type>\S+)', 'IgnoreCase')
    if ($match.Success -and $match.Groups['Name'].Value -in $monitorNames) {
        [pscustomobject]@{
            Name = $match.Groups['Name'].Value
            Type = $match.Groups['Type'].Value
            Line = $line
        }
    }
}

$lbVserverNames = @(
    foreach ($line in $lines) {
        $match = [regex]::Match($line, '^\s*bind\s+lb\s+vserver\s+(?<Vserver>\S+)\s+(?<Service>\S+)', 'IgnoreCase')
        if ($match.Success -and $match.Groups['Service'].Value -in $serviceNames) {
            $match.Groups['Vserver'].Value
        }

        $match = [regex]::Match($line, '^\s*bind\s+lb\s+vserver\s+(?<Vserver>\S+)\s+-serviceGroupName\s+(?<Group>\S+)', 'IgnoreCase')
        if ($match.Success -and $match.Groups['Group'].Value -in $serviceGroupNames) {
            $match.Groups['Vserver'].Value
        }

        $match = [regex]::Match($line, '^\s*bind\s+lb\s+vserver\s+(?<Vserver>\S+)\s+(?<Group>\S+)(?:\s|$)', 'IgnoreCase')
        if ($match.Success -and $match.Groups['Group'].Value -in $serviceGroupNames) {
            $match.Groups['Vserver'].Value
        }
    }
) | Sort-Object -Unique

$lbVservers = foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*add\s+lb\s+vserver\s+(?<Name>\S+)\s+(?<Protocol>\S+)\s+(?<Address>\S+)\s+(?<Port>\d+)', 'IgnoreCase')
    if ($match.Success -and $match.Groups['Name'].Value -in $lbVserverNames) {
        [pscustomobject]@{
            Name       = $match.Groups['Name'].Value
            Protocol   = $match.Groups['Protocol'].Value
            Address    = $match.Groups['Address'].Value
            Port       = [int]$match.Groups['Port'].Value
            Persistence = Get-NetScalerOption -Line $line -Name 'persistenceType'
            LoadMethod = Get-NetScalerOption -Line $line -Name 'lbMethod'
            Line       = $line
        }
    }
}

$peerServers = @(
    foreach ($line in $lines) {
        $serviceBinding = [regex]::Match($line, '^\s*bind\s+lb\s+vserver\s+(?<Vserver>\S+)\s+(?<Service>\S+)', 'IgnoreCase')
        if ($serviceBinding.Success -and $serviceBinding.Groups['Vserver'].Value -in $lbVserverNames) {
            $boundService = $allServices | Where-Object { $_.Name -ieq $serviceBinding.Groups['Service'].Value } | Select-Object -First 1
            if ($null -ne $boundService -and $boundService.Server -ine $server[0].Name) {
                $peerServer = $allServers | Where-Object { $_.Name -ieq $boundService.Server } | Select-Object -First 1
                [pscustomobject]@{
                    Name                    = $boundService.Server
                    Address                 = $peerServer.Address
                    Service                 = $boundService.Name
                    LoadBalancingVserver    = $serviceBinding.Groups['Vserver'].Value
                }
            }
        }

        $serviceGroupBinding = [regex]::Match($line, '^\s*bind\s+lb\s+vserver\s+(?<Vserver>\S+)\s+-serviceGroupName\s+(?<Group>\S+)', 'IgnoreCase')
        if ($serviceGroupBinding.Success -and $serviceGroupBinding.Groups['Vserver'].Value -in $lbVserverNames) {
            $allServiceGroupMembers |
                Where-Object { $_.Name -ieq $serviceGroupBinding.Groups['Group'].Value -and $_.Server -ine $server[0].Name } |
                ForEach-Object {
                    $member = $_
                    [pscustomobject]@{
                        Name                 = $member.Server
                        Address              = $serverAddresses[$member.Server]
                        Service              = $member.Name
                        LoadBalancingVserver = $serviceGroupBinding.Groups['Vserver'].Value
                    }
                }
        }

        $positionalServiceGroupBinding = [regex]::Match($line, '^\s*bind\s+lb\s+vserver\s+(?<Vserver>\S+)\s+(?<Group>\S+)(?:\s|$)', 'IgnoreCase')
        if ($positionalServiceGroupBinding.Success -and $positionalServiceGroupBinding.Groups['Vserver'].Value -in $lbVserverNames -and $positionalServiceGroupBinding.Groups['Group'].Value -in $serviceGroupNames) {
            $allServiceGroupMembers |
                Where-Object { $_.Name -ieq $positionalServiceGroupBinding.Groups['Group'].Value -and $_.Server -ine $server[0].Name } |
                ForEach-Object {
                    $member = $_
                    [pscustomobject]@{
                        Name                 = $member.Server
                        Address              = $serverAddresses[$member.Server]
                        Service              = $member.Name
                        LoadBalancingVserver = $positionalServiceGroupBinding.Groups['Vserver'].Value
                    }
                }
        }
    }
) | Sort-Object Name, Service, LoadBalancingVserver -Unique

$csActionTargets = @{}
foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*add\s+cs\s+action\s+(?<Action>\S+)\s+-targetLBVserver\s+(?<Vserver>\S+)', 'IgnoreCase')
    if ($match.Success) {
        $csActionTargets[$match.Groups['Action'].Value] = $match.Groups['Vserver'].Value
    }
}

$csPolicyActions = @{}
foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*add\s+cs\s+policy\s+(?<Policy>\S+)\s+.*?-action\s+(?<Action>\S+)', 'IgnoreCase')
    if ($match.Success -and $csActionTargets.ContainsKey($match.Groups['Action'].Value) -and $csActionTargets[$match.Groups['Action'].Value] -in $lbVserverNames) {
        $csPolicyActions[$match.Groups['Policy'].Value] = $match.Groups['Action'].Value
    }
}

$contentSwitchingVservers = foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*bind\s+cs\s+vserver\s+(?<Vserver>\S+)\s+-policyName\s+(?<Policy>\S+)', 'IgnoreCase')
    if ($match.Success -and $csPolicyActions.ContainsKey($match.Groups['Policy'].Value)) {
        $csVserverLine = $lines | Where-Object { $_ -match "^\s*add\s+cs\s+vserver\s+$([regex]::Escape($match.Groups['Vserver'].Value))\s+" } | Select-Object -First 1
        $csMatch = [regex]::Match($csVserverLine, '^\s*add\s+cs\s+vserver\s+(?<Name>\S+)\s+(?<Protocol>\S+)\s+(?<Address>\S+)\s+(?<Port>\d+)', 'IgnoreCase')

        [pscustomobject]@{
            Name           = $match.Groups['Vserver'].Value
            Protocol       = $csMatch.Groups['Protocol'].Value
            Address        = $csMatch.Groups['Address'].Value
            Port           = [int]$csMatch.Groups['Port'].Value
            Policy         = $match.Groups['Policy'].Value
            Action         = $csPolicyActions[$match.Groups['Policy'].Value]
            TargetLBVserver = $csActionTargets[$csPolicyActions[$match.Groups['Policy'].Value]]
            Line           = $csVserverLine
        }
    }
}

$vserverNames = Get-UniqueSorted @(
    $lbVservers | ForEach-Object { $_.Name }
    $contentSwitchingVservers | ForEach-Object { $_.Name }
)
$vserverBindings = foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*bind\s+(?:lb|cs)\s+vserver\s+(?<Vserver>\S+)', 'IgnoreCase')
    if ($match.Success -and $match.Groups['Vserver'].Value -in $vserverNames) {
        $line
    }
}

$certificateBindings = foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*bind\s+ssl\s+vserver\s+(?<Vserver>\S+)\s+-certkeyName\s+(?<Certificate>\S+)', 'IgnoreCase')
    if ($match.Success -and $match.Groups['Vserver'].Value -in $vserverNames) {
        [pscustomobject]@{
            Vserver     = $match.Groups['Vserver'].Value
            Certificate = $match.Groups['Certificate'].Value
            Line        = $line
        }
    }
}

$processedLines = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($item in @(
        $server
        $services
        $serviceGroupMembers
        $serviceGroupSslConfiguration
        $monitors
        $lbVservers
        $contentSwitchingVservers
        $certificateBindings
    )) {
    if ($null -ne $item -and $item.PSObject.Properties.Match('Line').Count -gt 0) {
        [void]$processedLines.Add($item.Line)
    }
}
foreach ($binding in $vserverBindings) {
    [void]$processedLines.Add($binding)
}

$relatedObjectNames = Get-UniqueSorted @(
    $server[0].Name
    $serviceNames
    $serviceGroupNames
    $lbVserverNames
    $contentSwitchingVservers | ForEach-Object { $_.Name }
)
$unprocessedRelevantLines = foreach ($line in $lines) {
    if ($processedLines.Contains($line)) {
        continue
    }

    foreach ($objectName in $relatedObjectNames) {
        if ($line -match [regex]::Escape($objectName)) {
            $line
            break
        }
    }
}

$result = [pscustomobject]@{
    Server                  = $server[0]
    PeerServers             = @($peerServers)
    Services                = @($services)
    ServiceGroups           = @($serviceGroupMembers)
    ServiceGroupSslConfiguration = @($serviceGroupSslConfiguration)
    Monitors                = @($monitors)
    LoadBalancingVservers   = @($lbVservers)
    ContentSwitchingVservers = @($contentSwitchingVservers)
    Certificates            = @($certificateBindings)
    VserverBindings         = @($vserverBindings)
    UnprocessedRelevantLines = @($unprocessedRelevantLines)
}

$selectedFormats = @($AsJson, $AsObject, $AsHtml) | Where-Object { $_ }
if (@($selectedFormats).Count -gt 1) {
    throw 'Specify only one of -AsJson, -AsObject, or -AsHtml.'
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 6
}
elseif ($AsObject) {
    $result
}
elseif ($AsHtml) {
    ConvertTo-NetScalerHtmlReport -Dependency $result -SourceConfigPath $ConfigPath
}
else {
    ConvertTo-NetScalerReport -Dependency $result -SourceConfigPath $ConfigPath
}
