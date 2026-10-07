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

function ConvertTo-NetScalerTextTable {
    param(
        [Parameter(Mandatory)]
        [object]$Report,

        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Description,

        [object[]]$Rows,

        [string[]]$Columns,

        [string[]]$RawCommands
    )

    $Report.Add('')
    $Report.Add($Title)
    $Report.Add(('-' * $Title.Length))
    $Report.Add($Description)

    if (@($Rows).Count -eq 0) {
        $Report.Add('  (none)')
    }
    else {
        $table = $Rows | Format-Table -Property $Columns -AutoSize | Out-String -Width 240
        foreach ($line in $table.TrimEnd().Split([Environment]::NewLine)) {
            $Report.Add($line)
        }
    }

    $commands = @($RawCommands | Where-Object { $_ } | Sort-Object -Unique)
    $Report.Add('Raw commands parsed:')
    if ($commands.Count -eq 0) {
        $Report.Add('  (none)')
    }
    else {
        foreach ($command in $commands) {
            $Report.Add("  $command")
        }
    }
}

function ConvertTo-NetScalerEnhancedTextReport {
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

    ConvertTo-NetScalerTextTable -Report $report -Title 'Selected server' -Description 'The backend server used as the starting point for the dependency walk.' -Rows @($Dependency.Server | Select-Object Name, Address) -Columns Name, Address -RawCommands @($Dependency.Server.Line)
    ConvertTo-NetScalerTextTable -Report $report -Title 'Peer servers' -Description 'Other backend servers sharing a discovered load-balancing vServer with the selected server.' -Rows @($Dependency.PeerServers | Select-Object Name, Address, Service, LoadBalancingVserver) -Columns Name, Address, Service, LoadBalancingVserver -RawCommands @($Dependency.PeerServers | ForEach-Object { $_.RawCommands })
    ConvertTo-NetScalerTextTable -Report $report -Title 'Services' -Description 'Direct service objects that point at the selected backend server.' -Rows @($Dependency.Services | Select-Object Name, Protocol, Port) -Columns Name, Protocol, Port -RawCommands @($Dependency.Services | ForEach-Object { $_.Line })
    ConvertTo-NetScalerTextTable -Report $report -Title 'Service groups' -Description 'Load-balancing service groups containing the selected backend server.' -Rows @($Dependency.ServiceGroups | Select-Object Name, Server, Port) -Columns Name, Server, Port -RawCommands @($Dependency.ServiceGroups | ForEach-Object { $_.Line })
    ConvertTo-NetScalerTextTable -Report $report -Title 'Service-group SSL configuration' -Description 'TLS settings and bindings applied to the selected server service groups.' -Rows @($Dependency.ServiceGroupSslConfiguration | Select-Object ServiceGroup, Line) -Columns ServiceGroup, Line -RawCommands @($Dependency.ServiceGroupSslConfiguration | ForEach-Object { $_.Line })
    ConvertTo-NetScalerTextTable -Report $report -Title 'Health monitors' -Description 'Health checks bound to the selected server services or service groups.' -Rows @($Dependency.Monitors | Select-Object Name, Type) -Columns Name, Type -RawCommands @($Dependency.Monitors | ForEach-Object { $_.Line })
    ConvertTo-NetScalerTextTable -Report $report -Title 'Load-balancing vServers' -Description 'Local virtual IP endpoints that route traffic to the selected server.' -Rows @($Dependency.LoadBalancingVservers | Select-Object Name, Protocol, Address, Port, LoadMethod, Persistence) -Columns Name, Protocol, Address, Port, LoadMethod, Persistence -RawCommands @($Dependency.LoadBalancingVservers | ForEach-Object { $_.Line })
    ConvertTo-NetScalerTextTable -Report $report -Title 'Content-switching vServers' -Description 'Content-switching front ends that route to discovered load-balancing vServers.' -Rows @($Dependency.ContentSwitchingVservers | Select-Object Name, Protocol, Address, Port, Policy, Action, TargetLBVserver) -Columns Name, Protocol, Address, Port, Policy, Action, TargetLBVserver -RawCommands @($Dependency.ContentSwitchingVservers | ForEach-Object { $_.Line })
    ConvertTo-NetScalerTextTable -Report $report -Title 'GSLB service groups' -Description 'Global service groups reached through a discovered local LB vServer VIP and port.' -Rows @($Dependency.GslbServiceGroups | Select-Object Name, ServiceType) -Columns Name, ServiceType -RawCommands @($Dependency.GslbServiceGroups | ForEach-Object { $_.Line })
    ConvertTo-NetScalerTextTable -Report $report -Title 'GSLB members' -Description 'Endpoints in the discovered global service groups, including any public NAT endpoint.' -Rows @($Dependency.GslbServiceGroupMembers | ForEach-Object { [pscustomobject]@{ Group = $_.GslbServiceGroup; Member = "$($_.Address):$($_.Port)"; PublicEndpoint = if ($_.PublicIp) { "$($_.PublicIp):$($_.PublicPort)" } else { '' }; LocalLBVservers = $_.DiscoveryLoadBalancingVservers -join ', ' } }) -Columns Group, Member, PublicEndpoint, LocalLBVservers -RawCommands @($Dependency.GslbServiceGroupMembers | ForEach-Object { $_.Line })
    ConvertTo-NetScalerTextTable -Report $report -Title 'GSLB monitors' -Description 'Health checks and configuration applied to discovered GSLB service groups.' -Rows @($Dependency.GslbMonitors | Select-Object Name, Type) -Columns Name, Type -RawCommands @($Dependency.GslbMonitorConfiguration | ForEach-Object { $_.Line })
    ConvertTo-NetScalerTextTable -Report $report -Title 'GSLB vServers and domains' -Description 'Global DNS-aware virtual servers and the domains they answer for.' -Rows @($Dependency.GslbVservers | Select-Object Name, ServiceType, ServiceGroup; $Dependency.GslbDomains | ForEach-Object { [pscustomobject]@{ Name = $_.Vserver; ServiceType = 'domain'; ServiceGroup = $_.Name } }) -Columns Name, ServiceType, ServiceGroup -RawCommands @($Dependency.GslbVservers | ForEach-Object { $_.Line; $_.BindingLine }; $Dependency.GslbDomains | ForEach-Object { $_.Line })
    ConvertTo-NetScalerTextTable -Report $report -Title 'Certificates' -Description 'SSL certificate-key bindings on discovered local or content-switching vServers.' -Rows @($Dependency.Certificates | Select-Object Vserver, Certificate) -Columns Vserver, Certificate -RawCommands @($Dependency.Certificates | ForEach-Object { $_.Line })
    ConvertTo-NetScalerTextTable -Report $report -Title 'Relevant vServer bindings' -Description 'Additional bindings associated with the discovered local and content-switching vServers.' -Rows @($Dependency.VserverBindings | ForEach-Object { [pscustomobject]@{ Command = $_ } }) -Columns Command -RawCommands @($Dependency.VserverBindings)
    ConvertTo-NetScalerTextTable -Report $report -Title 'Unprocessed related lines' -Description 'Related commands retained for inspection because they are not interpreted by this report.' -Rows @($Dependency.UnprocessedRelevantLines | ForEach-Object { [pscustomobject]@{ Command = $_ } }) -Columns Command -RawCommands @($Dependency.UnprocessedRelevantLines)

    $report -join [Environment]::NewLine
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
    $report.Add('GSLB service-group members')
    $report.Add('--------------------------')
    if ($Dependency.GslbServiceGroupMembers.Count -eq 0) {
        $report.Add('  (none)')
    }
    foreach ($member in $Dependency.GslbServiceGroupMembers) {
        $publicEndpoint = if ($member.PublicIp) { " public=$($member.PublicIp):$($member.PublicPort)" } else { '' }
        $discoverySource = $member.DiscoveryLoadBalancingVservers -join ', '
        $report.Add("  $($member.GslbServiceGroup): $($member.Address):$($member.Port)$publicEndpoint [discovered from LB vServer: $discoverySource]")
    }

    $report.Add('')
    $report.Add('GSLB service-group configuration')
    $report.Add('--------------------------------')
    if ($Dependency.GslbServiceGroups.Count -eq 0) {
        $report.Add('  (none)')
    }
    foreach ($serviceGroup in $Dependency.GslbServiceGroups) {
        $report.Add("  $($serviceGroup.Name) ($($serviceGroup.ServiceType))")
    }

    $report.Add('')
    $report.Add('GSLB health monitors')
    $report.Add('--------------------')
    if ($Dependency.GslbMonitors.Count -eq 0) {
        $report.Add('  (none)')
    }
    foreach ($monitor in $Dependency.GslbMonitors) {
        $report.Add("  $($monitor.Name) ($($monitor.Type))")
    }
    foreach ($configuration in $Dependency.GslbMonitorConfiguration) {
        $report.Add("  $($configuration.Line)")
    }

    $report.Add('')
    $report.Add('GSLB vServers')
    $report.Add('-------------')
    if ($Dependency.GslbVservers.Count -eq 0) {
        $report.Add('  (none)')
    }
    foreach ($vserver in $Dependency.GslbVservers) {
        $serviceType = if ($vserver.ServiceType) { " ($($vserver.ServiceType))" } else { '' }
        $report.Add("  $($vserver.Name)$serviceType -> $($vserver.ServiceGroup)")
    }

    $report.Add('')
    $report.Add('GSLB domains')
    $report.Add('------------')
    if ($Dependency.GslbDomains.Count -eq 0) {
        $report.Add('  (none)')
    }
    foreach ($domain in $Dependency.GslbDomains) {
        $report.Add("  $($domain.Vserver): $($domain.Name)")
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
    $report.Add('Unprocessed lines for all discovered objects')
    $report.Add('--------------------------------------------')
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

    function ConvertTo-HtmlCommandBlock {
        param([string[]]$Commands)

        $parsedCommands = @($Commands | Where-Object { $_ } | Sort-Object -Unique)
        if ($parsedCommands.Count -eq 0) {
            return '<details class="commands"><summary>Raw commands parsed</summary><p class="empty">(none)</p></details>'
        }

        $encodedCommands = ($parsedCommands | ForEach-Object {
                [System.Net.WebUtility]::HtmlEncode($_)
            }) -join [Environment]::NewLine
        "<details class=""commands""><summary>Raw commands parsed</summary><pre>$encodedCommands</pre></details>"
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
    $gslbMemberRows = ConvertTo-HtmlRows -Items @($Dependency.GslbServiceGroupMembers) -Row {
        param($member)
        $publicEndpoint = if ($member.PublicIp) { "$($member.PublicIp):$($member.PublicPort)" } else { '' }
        "<tr><td>$(ConvertTo-HtmlText $member.GslbServiceGroup)</td><td>$(ConvertTo-HtmlText "$($member.Address):$($member.Port)")</td><td>$(ConvertTo-HtmlText $publicEndpoint)</td><td>$(ConvertTo-HtmlText ($member.DiscoveryLoadBalancingVservers -join ', '))</td></tr>"
    }
    $gslbServiceGroupRows = ConvertTo-HtmlRows -Items @($Dependency.GslbServiceGroups) -Row {
        param($serviceGroup)
        "<tr><td>$(ConvertTo-HtmlText $serviceGroup.Name)</td><td>$(ConvertTo-HtmlText $serviceGroup.ServiceType)</td><td><code>$(ConvertTo-HtmlText $serviceGroup.Line)</code></td></tr>"
    }
    $gslbVserverRows = ConvertTo-HtmlRows -Items @($Dependency.GslbVservers) -Row {
        param($vserver)
        "<tr><td>$(ConvertTo-HtmlText $vserver.Name)</td><td>$(ConvertTo-HtmlText $vserver.ServiceType)</td><td>$(ConvertTo-HtmlText $vserver.ServiceGroup)</td></tr>"
    }
    $gslbDomainRows = ConvertTo-HtmlRows -Items @($Dependency.GslbDomains) -Row {
        param($domain)
        "<tr><td>$(ConvertTo-HtmlText $domain.Vserver)</td><td>$(ConvertTo-HtmlText $domain.Name)</td></tr>"
    }
    $gslbMonitorRows = ConvertTo-HtmlRows -Items @($Dependency.GslbMonitors) -Row {
        param($monitor)
        "<tr><td>$(ConvertTo-HtmlText $monitor.Name)</td><td>$(ConvertTo-HtmlText $monitor.Type)</td></tr>"
    }
    $gslbMonitorConfigurationRows = ConvertTo-HtmlRows -Items @($Dependency.GslbMonitorConfiguration) -Row {
        param($configuration)
        "<tr><td colspan=""2""><code>$(ConvertTo-HtmlText $configuration.Line)</code></td></tr>"
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
    $serverCommands = ConvertTo-HtmlCommandBlock @($Dependency.Server.Line)
    $peerCommands = ConvertTo-HtmlCommandBlock @($Dependency.PeerServers | ForEach-Object { $_.RawCommands })
    $serviceCommands = ConvertTo-HtmlCommandBlock @($Dependency.Services | ForEach-Object { $_.Line })
    $serviceGroupCommands = ConvertTo-HtmlCommandBlock @($Dependency.ServiceGroups | ForEach-Object { $_.Line })
    $serviceGroupSslCommands = ConvertTo-HtmlCommandBlock @($Dependency.ServiceGroupSslConfiguration | ForEach-Object { $_.Line })
    $monitorCommands = ConvertTo-HtmlCommandBlock @($Dependency.Monitors | ForEach-Object { $_.Line })
    $lbVserverCommands = ConvertTo-HtmlCommandBlock @($Dependency.LoadBalancingVservers | ForEach-Object { $_.Line })
    $csVserverCommands = ConvertTo-HtmlCommandBlock @($Dependency.ContentSwitchingVservers | ForEach-Object { $_.Line })
    $gslbMemberCommands = ConvertTo-HtmlCommandBlock @($Dependency.GslbServiceGroupMembers | ForEach-Object { $_.Line })
    $gslbServiceGroupCommands = ConvertTo-HtmlCommandBlock @($Dependency.GslbServiceGroups | ForEach-Object { $_.Line })
    $gslbMonitorCommands = ConvertTo-HtmlCommandBlock @($Dependency.GslbMonitorConfiguration | ForEach-Object { $_.Line })
    $gslbVserverCommands = ConvertTo-HtmlCommandBlock @($Dependency.GslbVservers | ForEach-Object { $_.Line; $_.BindingLine })
    $gslbDomainCommands = ConvertTo-HtmlCommandBlock @($Dependency.GslbDomains | ForEach-Object { $_.Line })
    $certificateCommands = ConvertTo-HtmlCommandBlock @($Dependency.Certificates | ForEach-Object { $_.Line })
    $bindingCommands = ConvertTo-HtmlCommandBlock @($Dependency.VserverBindings)
    $unprocessedCommands = ConvertTo-HtmlCommandBlock @($Dependency.UnprocessedRelevantLines)

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
th { background: #f3f4f6; } code { overflow-wrap: anywhere; } .empty { color: #6b7280; font-style: italic; } .metadata, .description { color: #4b5563; } details.commands { margin: 0.5rem 0 1rem; } details.commands summary { cursor: pointer; font-weight: 600; } details.commands pre { overflow-x: auto; white-space: pre-wrap; }
</style>
</head>
<body>
<h1>NetScaler server dependency report</h1>
<p class="metadata">Config: <code>$(ConvertTo-HtmlText $SourceConfigPath)</code></p>
<h2>Server</h2>
<p class="description">The backend server used as the starting point for the dependency walk.</p>
<table><thead><tr><th>Name</th><th>Address</th></tr></thead><tbody>
<tr><td>$(ConvertTo-HtmlText $Dependency.Server.Name)</td><td>$(ConvertTo-HtmlText $Dependency.Server.Address)</td></tr>
</tbody></table>
$serverCommands
<h2>Peer servers sharing a load-balancing vServer</h2>
<p class="description">Other backends that share a discovered local load-balancing vServer.</p>
<table><thead><tr><th>Name</th><th>Address</th><th>Service</th><th>Shared LB vServer</th></tr></thead><tbody>$peerServerRows</tbody></table>
$peerCommands
<h2>Services</h2>
<p class="description">Direct service objects that point to the selected backend server.</p>
<table><thead><tr><th>Name</th><th>Protocol / port</th></tr></thead><tbody>$serviceRows</tbody></table>
$serviceCommands
<h2>Service groups</h2>
<p class="description">Load-balancing service groups that contain the selected backend server.</p>
<table><thead><tr><th>Name</th><th>Member port</th></tr></thead><tbody>$serviceGroupRows</tbody></table>
$serviceGroupCommands
<h2>Service-group SSL configuration</h2>
<p class="description">TLS configuration applied to the selected server service groups.</p>
<table><thead><tr><th>Configuration line</th></tr></thead><tbody>$serviceGroupSslRows</tbody></table>
$serviceGroupSslCommands
<h2>Health monitors</h2>
<p class="description">Health checks attached to the selected server services or service groups.</p>
<table><thead><tr><th>Name</th><th>Type</th></tr></thead><tbody>$monitorRows</tbody></table>
$monitorCommands
<h2>Load-balancing vServers</h2>
<p class="description">Local virtual IP endpoints that distribute traffic to the selected backend.</p>
<table><thead><tr><th>Name</th><th>VIP</th><th>Settings</th></tr></thead><tbody>$lbVserverRows</tbody></table>
$lbVserverCommands
<h2>Content-switching vServers</h2>
<p class="description">Front-end virtual servers that use policies to route requests to discovered load-balancing vServers.</p>
<table><thead><tr><th>Name</th><th>VIP</th><th>Route</th></tr></thead><tbody>$csVserverRows</tbody></table>
$csVserverCommands
<h2>GSLB service-group members</h2>
<p class="description">Global service endpoints correlated from discovered local LB VIP and port pairs.</p>
<table><thead><tr><th>GSLB service group</th><th>Member endpoint</th><th>Public endpoint</th><th>Local LB vServers</th></tr></thead><tbody>$gslbMemberRows</tbody></table>
$gslbMemberCommands
<h2>GSLB service-group configuration</h2>
<p class="description">Definitions and service types for the discovered global service groups.</p>
<table><thead><tr><th>Name</th><th>Service type</th><th>Definition</th></tr></thead><tbody>$gslbServiceGroupRows</tbody></table>
$gslbServiceGroupCommands
<h2>GSLB health monitors</h2>
<p class="description">Health checks and monitor settings attached to discovered global service groups.</p>
<table><thead><tr><th>Name</th><th>Type</th></tr></thead><tbody>$gslbMonitorRows</tbody></table>
<table><thead><tr><th>Monitor configuration lines</th></tr></thead><tbody>$gslbMonitorConfigurationRows</tbody></table>
$gslbMonitorCommands
<h2>GSLB vServers</h2>
<p class="description">Global DNS-aware virtual servers that use the discovered GSLB service groups.</p>
<table><thead><tr><th>Name</th><th>Service type</th><th>GSLB service group</th></tr></thead><tbody>$gslbVserverRows</tbody></table>
$gslbVserverCommands
<h2>GSLB domains</h2>
<p class="description">Domain names bound to discovered GSLB virtual servers.</p>
<table><thead><tr><th>GSLB vServer</th><th>Domain name</th></tr></thead><tbody>$gslbDomainRows</tbody></table>
$gslbDomainCommands
<h2>Certificate bindings</h2>
<p class="description">Certificate-key bindings on discovered local and content-switching virtual servers.</p>
<table><thead><tr><th>vServer</th><th>Certificate</th></tr></thead><tbody>$certificateRows</tbody></table>
$certificateCommands
<h2>Relevant vServer bindings</h2>
<p class="description">Additional bindings associated with the discovered local and content-switching virtual servers.</p>
<table><thead><tr><th>Binding</th></tr></thead><tbody>$bindingRows</tbody></table>
$bindingCommands
<h2>Unprocessed lines for all discovered objects</h2>
<p class="description">Related commands kept for inspection because this report does not interpret them.</p>
<table><thead><tr><th>Configuration line</th></tr></thead><tbody>$unprocessedLineRows</tbody></table>
$unprocessedCommands
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

$monitorBindingLines = @()
$monitorNames = @(
    foreach ($line in $lines) {
        $match = [regex]::Match($line, '^\s*bind\s+service\s+(?<Service>\S+)\s+-monitorName\s+(?<Monitor>\S+)', 'IgnoreCase')
        if ($match.Success -and $match.Groups['Service'].Value -in $serviceNames) {
            $monitorBindingLines += $line
            $match.Groups['Monitor'].Value
        }

        $match = [regex]::Match($line, '^\s*bind\s+serviceGroup\s+(?<Group>\S+)\s+-monitorName\s+(?<Monitor>\S+)', 'IgnoreCase')
        if ($match.Success -and $match.Groups['Group'].Value -in $serviceGroupNames) {
            $monitorBindingLines += $line
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

        $match = [regex]::Match($line, '^\s*bind\s+lb\s+vserver\s+(?<Vserver>\S+)\s+-serviceName\s+(?<Service>\S+)', 'IgnoreCase')
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

$gslbServiceGroupDiscoveries = @(
    foreach ($line in $lines) {
        $match = [regex]::Match($line, '^\s*bind\s+gslb\s+serviceGroup\s+(?<Group>\S+)\s+(?<Address>\S+)\s+(?<Port>\d+)', 'IgnoreCase')
        if ($match.Success) {
            $matchingVservers = @($lbVservers | Where-Object {
                    $_.Address -eq $match.Groups['Address'].Value -and $_.Port -eq [int]$match.Groups['Port'].Value
                } | ForEach-Object { $_.Name })
            if ($matchingVservers.Count -gt 0) {
                [pscustomobject]@{
                    Group                         = $match.Groups['Group'].Value
                    LoadBalancingVservers         = $matchingVservers
                }
            }
        }
    }
)
$gslbServiceGroupNames = Get-UniqueSorted @($gslbServiceGroupDiscoveries | ForEach-Object { $_.Group })
$gslbDiscoveryVserversByGroup = @{}
foreach ($groupName in $gslbServiceGroupNames) {
    $gslbDiscoveryVserversByGroup[$groupName] = Get-UniqueSorted @(
        $gslbServiceGroupDiscoveries |
            Where-Object { $_.Group -ieq $groupName } |
            ForEach-Object { $_.LoadBalancingVservers }
    )
}

$gslbServiceGroups = foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*add\s+gslb\s+serviceGroup\s+(?<Name>\S+)\s+(?<ServiceType>\S+)', 'IgnoreCase')
    if ($match.Success -and $match.Groups['Name'].Value -in $gslbServiceGroupNames) {
        [pscustomobject]@{
            Name        = $match.Groups['Name'].Value
            ServiceType = $match.Groups['ServiceType'].Value
            Line        = $line
        }
    }
}

$gslbServiceGroupMembers = foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*bind\s+gslb\s+serviceGroup\s+(?<Group>\S+)\s+(?<Address>\S+)\s+(?<Port>\d+)', 'IgnoreCase')
    if ($match.Success -and $match.Groups['Group'].Value -in $gslbServiceGroupNames) {
        [pscustomobject]@{
            GslbServiceGroup                = $match.Groups['Group'].Value
            Address                         = $match.Groups['Address'].Value
            Port                            = [int]$match.Groups['Port'].Value
            PublicIp                        = Get-NetScalerOption -Line $line -Name 'publicIP'
            PublicPort                      = Get-NetScalerOption -Line $line -Name 'publicPort'
            DiscoveryLoadBalancingVservers  = $gslbDiscoveryVserversByGroup[$match.Groups['Group'].Value]
            Line                            = $line
        }
    }
}

$gslbVserverBindings = foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*bind\s+gslb\s+vserver\s+(?<Vserver>\S+)\s+-serviceGroupName\s+(?<Group>\S+)', 'IgnoreCase')
    if ($match.Success -and $match.Groups['Group'].Value -in $gslbServiceGroupNames) {
        [pscustomobject]@{ Name = $match.Groups['Vserver'].Value; ServiceGroup = $match.Groups['Group'].Value; BindingLine = $line }
    }
}

$gslbVservers = foreach ($binding in $gslbVserverBindings) {
    $definitionLine = $lines | Where-Object { $_ -match "^\s*add\s+gslb\s+vserver\s+$([regex]::Escape($binding.Name))\s+" } | Select-Object -First 1
    $definition = if ($definitionLine) { [regex]::Match($definitionLine, '^\s*add\s+gslb\s+vserver\s+(?<Name>\S+)\s+(?<ServiceType>\S+)', 'IgnoreCase') }
    [pscustomobject]@{
        Name = $binding.Name
        ServiceType = if ($null -ne $definition -and $definition.Success) { $definition.Groups['ServiceType'].Value } else { $null }
        ServiceGroup = $binding.ServiceGroup
        BindingLine = $binding.BindingLine
        Line = $definitionLine
    }
}

$gslbVserverNames = Get-UniqueSorted @($gslbVservers | ForEach-Object { $_.Name })
$gslbDomains = foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*bind\s+gslb\s+vserver\s+(?<Vserver>\S+)\s+-domainName\s+(?<Domain>\S+)', 'IgnoreCase')
    if ($match.Success -and $match.Groups['Vserver'].Value -in $gslbVserverNames) {
        [pscustomobject]@{
            Vserver = $match.Groups['Vserver'].Value
            Name    = $match.Groups['Domain'].Value
            Line    = $line
        }
    }
}

$gslbMonitorBindingLines = @()
$gslbMonitorNames = @(
    foreach ($line in $lines) {
        $match = [regex]::Match($line, '^\s*bind\s+gslb\s+serviceGroup\s+(?<Group>\S+)\s+-monitorName\s+(?<Monitor>\S+)', 'IgnoreCase')
        if ($match.Success -and $match.Groups['Group'].Value -in $gslbServiceGroupNames) {
            $gslbMonitorBindingLines += $line
            $match.Groups['Monitor'].Value
        }
    }
) | Sort-Object -Unique
$gslbMonitors = foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*add\s+lb\s+monitor\s+(?<Name>\S+)\s+(?<Type>\S+)', 'IgnoreCase')
    if ($match.Success -and $match.Groups['Name'].Value -in $gslbMonitorNames) {
        [pscustomobject]@{
            Name = $match.Groups['Name'].Value
            Type = $match.Groups['Type'].Value
            Line = $line
        }
    }
    $gslbMonitorConfiguration = foreach ($line in $lines) {
        $match = [regex]::Match($line, '^\s*(?:add|set)\s+lb\s+monitor\s+(?<Name>\S+)', 'IgnoreCase')
        if ($match.Success -and $match.Groups['Name'].Value -in $gslbMonitorNames) {
            [pscustomobject]@{
                Name = $match.Groups['Name'].Value
                Line = $line
            }
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
                    RawCommands             = @($peerServer.Line, $boundService.Line, $line)
                }
            }
        }

        $namedServiceBinding = [regex]::Match($line, '^\s*bind\s+lb\s+vserver\s+(?<Vserver>\S+)\s+-serviceName\s+(?<Service>\S+)', 'IgnoreCase')
        if ($namedServiceBinding.Success -and $namedServiceBinding.Groups['Vserver'].Value -in $lbVserverNames) {
            $boundService = $allServices | Where-Object { $_.Name -ieq $namedServiceBinding.Groups['Service'].Value } | Select-Object -First 1
            if ($null -ne $boundService -and $boundService.Server -ine $server[0].Name) {
                $peerServer = $allServers | Where-Object { $_.Name -ieq $boundService.Server } | Select-Object -First 1
                [pscustomobject]@{
                    Name                    = $boundService.Server
                    Address                 = $peerServer.Address
                    Service                 = $boundService.Name
                    LoadBalancingVserver    = $namedServiceBinding.Groups['Vserver'].Value
                    RawCommands             = @($peerServer.Line, $boundService.Line, $line)
                }
            }
        }

        $serviceGroupBinding = [regex]::Match($line, '^\s*bind\s+lb\s+vserver\s+(?<Vserver>\S+)\s+-serviceGroupName\s+(?<Group>\S+)', 'IgnoreCase')
        if ($serviceGroupBinding.Success -and $serviceGroupBinding.Groups['Vserver'].Value -in $lbVserverNames) {
            $allServiceGroupMembers |
                Where-Object { $_.Name -ieq $serviceGroupBinding.Groups['Group'].Value -and $_.Server -ine $server[0].Name } |
                ForEach-Object {
                    $member = $_
                    $peerServer = $allServers | Where-Object { $_.Name -ieq $member.Server } | Select-Object -First 1
                    [pscustomobject]@{
                        Name                 = $member.Server
                        Address              = $serverAddresses[$member.Server]
                        Service              = $member.Name
                        LoadBalancingVserver = $serviceGroupBinding.Groups['Vserver'].Value
                        RawCommands          = @($peerServer.Line, $member.Line, $line)
                    }
                }
        }

        $positionalServiceGroupBinding = [regex]::Match($line, '^\s*bind\s+lb\s+vserver\s+(?<Vserver>\S+)\s+(?<Group>\S+)(?:\s|$)', 'IgnoreCase')
        if ($positionalServiceGroupBinding.Success -and $positionalServiceGroupBinding.Groups['Vserver'].Value -in $lbVserverNames -and $positionalServiceGroupBinding.Groups['Group'].Value -in $serviceGroupNames) {
            $allServiceGroupMembers |
                Where-Object { $_.Name -ieq $positionalServiceGroupBinding.Groups['Group'].Value -and $_.Server -ine $server[0].Name } |
                ForEach-Object {
                    $member = $_
                    $peerServer = $allServers | Where-Object { $_.Name -ieq $member.Server } | Select-Object -First 1
                    [pscustomobject]@{
                        Name                 = $member.Server
                        Address              = $serverAddresses[$member.Server]
                        Service              = $member.Name
                        LoadBalancingVserver = $positionalServiceGroupBinding.Groups['Vserver'].Value
                        RawCommands          = @($peerServer.Line, $member.Line, $line)
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
    if ($match.Success) {
        $action = $null
        $targetLBVserver = Get-NetScalerOption -Line $line -Name 'targetLBVserver'
        if ($csPolicyActions.ContainsKey($match.Groups['Policy'].Value)) {
            $action = $csPolicyActions[$match.Groups['Policy'].Value]
            $targetLBVserver = $csActionTargets[$action]
        }

        if ($targetLBVserver -notin $lbVserverNames) {
            continue
        }

        $csVserverLine = $lines | Where-Object { $_ -match "^\s*add\s+cs\s+vserver\s+$([regex]::Escape($match.Groups['Vserver'].Value))\s+" } | Select-Object -First 1
        $csMatch = [regex]::Match($csVserverLine, '^\s*add\s+cs\s+vserver\s+(?<Name>\S+)\s+(?<Protocol>\S+)\s+(?<Address>\S+)\s+(?<Port>\d+)', 'IgnoreCase')

        [pscustomobject]@{
            Name           = $match.Groups['Vserver'].Value
            Protocol       = $csMatch.Groups['Protocol'].Value
            Address        = $csMatch.Groups['Address'].Value
            Port           = [int]$csMatch.Groups['Port'].Value
            Policy         = $match.Groups['Policy'].Value
            Action         = $action
            TargetLBVserver = $targetLBVserver
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
        $gslbServiceGroups
        $gslbServiceGroupMembers
        $gslbVservers
        $gslbDomains
        $gslbMonitors
        $gslbMonitorConfiguration
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
foreach ($peerServer in $peerServers) {
    foreach ($command in $peerServer.RawCommands) {
        [void]$processedLines.Add($command)
    }
}
foreach ($binding in $monitorBindingLines) {
    [void]$processedLines.Add($binding)
}
foreach ($binding in $gslbMonitorBindingLines) {
    [void]$processedLines.Add($binding)
}
foreach ($binding in $gslbVserverBindings) {
    [void]$processedLines.Add($binding.BindingLine)
}

$relatedObjectNames = Get-UniqueSorted @(
    $server[0].Name
    $serviceNames
    $serviceGroupNames
    $monitorNames
    $gslbMonitorNames
    $lbVserverNames
    $peerServers | ForEach-Object { $_.Name }
    $contentSwitchingVservers | ForEach-Object { $_.Name; $_.Policy; $_.Action }
    $certificateBindings | ForEach-Object { $_.Certificate }
    $gslbServiceGroupMembers | ForEach-Object { $_.GslbServiceGroup }
    $gslbServiceGroups | ForEach-Object { $_.Name }
    $gslbVservers | ForEach-Object { $_.Name; $_.ServiceGroup }
    $gslbDomains | ForEach-Object { $_.Name }
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
    GslbServiceGroups        = @($gslbServiceGroups)
    GslbServiceGroupMembers = @($gslbServiceGroupMembers)
    GslbVservers            = @($gslbVservers)
    GslbDomains              = @($gslbDomains)
    GslbMonitors             = @($gslbMonitors)
    GslbMonitorConfiguration = @($gslbMonitorConfiguration)
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
    ConvertTo-NetScalerEnhancedTextReport -Dependency $result -SourceConfigPath $ConfigPath
}
