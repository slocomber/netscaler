<#
.SYNOPSIS
Finds the NetScaler objects that expose a backend server.

.DESCRIPTION
Renders at most 100 rows per report section by default. Use -MaxRowsPerSection to select a lower limit.

.EXAMPLE
.\Get-NetScalerServerDependency.ps1 -ConfigPath .\sample-netscaler.conf -ServerName api-app-01

.EXAMPLE
.\Get-NetScalerServerDependency.ps1 -ConfigPath C:\Exports\ns.conf -ServerName api-app-01 -AsJson

.EXAMPLE
.\Get-NetScalerServerDependency.ps1 -ConfigPath C:\Exports\ns.conf -ServerName api-app-01 -AsObject

.EXAMPLE
.\Get-NetScalerServerDependency.ps1 -ConfigPath C:\Exports\ns.conf -ServerName api-app-01 -AsHtml

Creates C:\Exports\dependency-report-api-app-01.html. Use -HtmlOutputPath to choose a different location.
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

    [switch]$AsHtml,

    [string]$HtmlOutputPath,

    [ValidateRange(1, 100)]
    [int]$MaxRowsPerSection = 100
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

function Add-NetScalerTextTable {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object]$Report,

        [AllowEmptyCollection()]
        [object[]]$Rows,

        [Parameter(Mandatory)]
        [object[]]$Columns,

        [Parameter(Mandatory)]
        [int]$MaxRows
    )

    if ($Rows.Count -eq 0) {
        $Report.Add('  (none)')
        return
    }

    $displayRows = @($Rows | Select-Object -First $MaxRows)
    $table = $displayRows | Format-Table -Property $Columns -AutoSize | Out-String -Width 240
    foreach ($line in $table.TrimEnd().Split([Environment]::NewLine)) {
        $Report.Add($line)
    }

    if ($Rows.Count -gt $MaxRows) {
        $Report.Add("  (showing first $MaxRows of $($Rows.Count) rows)")
    }
}

function Add-NetScalerBoundedLines {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object]$Report,

        [AllowEmptyCollection()]
        [object[]]$Lines,

        [Parameter(Mandatory)]
        [int]$MaxRows
    )

    if ($Lines.Count -eq 0) {
        $Report.Add('  (none)')
        return
    }

    foreach ($line in @($Lines | Select-Object -First $MaxRows)) {
        $Report.Add("  $line")
    }

    if ($Lines.Count -gt $MaxRows) {
        $Report.Add("  (showing first $MaxRows of $($Lines.Count) rows)")
    }
}

function Add-NetScalerRawCommands {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object]$Report,

        [AllowEmptyCollection()]
        [object[]]$Commands,

        [Parameter(Mandatory)]
        [int]$MaxRows
    )

    $uniqueCommands = @($Commands | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $Report.Add('Raw commands interpreted:')
    Add-NetScalerBoundedLines -Report $Report -Lines $uniqueCommands -MaxRows $MaxRows
}

function ConvertTo-NetScalerReport {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Dependency,

        [Parameter(Mandatory)]
        [string]$SourceConfigPath,

        [Parameter(Mandatory)]
        [int]$MaxRowsPerSection
    )

    $report = [System.Collections.Generic.List[string]]::new()
    $report.Add('NetScaler server dependency report')
    $report.Add(('=' * 34))
    $report.Add("Config:  $SourceConfigPath")
    $report.Add("Server:  $($Dependency.Server.Name) ($($Dependency.Server.Address))")
    Add-NetScalerRawCommands -Report $report -Commands @($Dependency.Server.Line) -MaxRows $MaxRowsPerSection

    $report.Add('')
    $report.Add('Peer servers sharing a load-balancing vServer')
    $report.Add('------------------------------------------------')
    $report.Add('Other backend servers that share a discovered local load-balancing vServer with the selected server.')
    Add-NetScalerTextTable -Report $report -Rows @($Dependency.PeerServers) -Columns Name, Address, Service, LoadBalancingVserver -MaxRows $MaxRowsPerSection
    Add-NetScalerRawCommands -Report $report -Commands @($Dependency.PeerServers | ForEach-Object { $_.RawCommands }) -MaxRows $MaxRowsPerSection

    $report.Add('')
    $report.Add('Services')
    $report.Add('--------')
    $report.Add('Direct service objects that point to the selected backend server.')
    Add-NetScalerTextTable -Report $report -Rows @($Dependency.Services) -Columns Name, Protocol, Port -MaxRows $MaxRowsPerSection
    Add-NetScalerRawCommands -Report $report -Commands @($Dependency.Services | ForEach-Object { $_.Line }) -MaxRows $MaxRowsPerSection

    $report.Add('')
    $report.Add('Service groups')
    $report.Add('--------------')
    $report.Add('Load-balancing service groups that contain the selected backend server.')
    $serviceGroupRows = @($Dependency.ServiceGroups | Select-Object Name, Server, Port)
    Add-NetScalerTextTable -Report $report -Rows $serviceGroupRows -Columns Name, Server, Port -MaxRows $MaxRowsPerSection
    Add-NetScalerRawCommands -Report $report -Commands @($Dependency.ServiceGroups | ForEach-Object { $_.Line }) -MaxRows $MaxRowsPerSection

    $report.Add('')
    $report.Add('Service-group SSL configuration')
    $report.Add('-------------------------------')
    $report.Add('TLS configuration applied to the selected server service groups.')
    Add-NetScalerBoundedLines -Report $report -Lines @($Dependency.ServiceGroupSslConfiguration | ForEach-Object { $_.Line }) -MaxRows $MaxRowsPerSection
    Add-NetScalerRawCommands -Report $report -Commands @($Dependency.ServiceGroupSslConfiguration | ForEach-Object { $_.Line }) -MaxRows $MaxRowsPerSection

    $report.Add('')
    $report.Add('Health monitors')
    $report.Add('---------------')
    $report.Add('Health checks bound to the selected server services or service groups.')
    Add-NetScalerTextTable -Report $report -Rows @($Dependency.Monitors) -Columns Name, Type -MaxRows $MaxRowsPerSection
    Add-NetScalerRawCommands -Report $report -Commands @($Dependency.Monitors | ForEach-Object { $_.Line }; $Dependency.MonitorBindingLines) -MaxRows $MaxRowsPerSection

    $report.Add('')
    $report.Add('Load-balancing vServers')
    $report.Add('------------------------')
    $report.Add('Local virtual IP endpoints that distribute traffic to the selected backend.')
    Add-NetScalerTextTable -Report $report -Rows @($Dependency.LoadBalancingVservers) -Columns Name, Protocol, Address, Port, LoadMethod, Persistence -MaxRows $MaxRowsPerSection
    Add-NetScalerRawCommands -Report $report -Commands @($Dependency.LoadBalancingVservers | ForEach-Object { $_.Line }) -MaxRows $MaxRowsPerSection

    $report.Add('')
    $report.Add('Content-switching vServers')
    $report.Add('--------------------------')
    $report.Add('Front-end virtual servers that use policies to route requests to discovered load-balancing vServers.')
    Add-NetScalerTextTable -Report $report -Rows @($Dependency.ContentSwitchingVservers) -Columns Name, Protocol, Address, Port, Policy, Action, TargetLBVserver -MaxRows $MaxRowsPerSection
    Add-NetScalerRawCommands -Report $report -Commands @($Dependency.ContentSwitchingVservers | ForEach-Object { $_.RawCommands }) -MaxRows $MaxRowsPerSection

    $report.Add('')
    $report.Add('GSLB service-group members')
    $report.Add('--------------------------')
    $report.Add('Global service endpoints correlated from discovered local load-balancing VIP and port pairs.')
    $gslbMemberRows = @($Dependency.GslbServiceGroupMembers | ForEach-Object {
            [pscustomobject]@{
                ServiceGroup = $_.GslbServiceGroup
                Address = $_.Address
                Port = $_.Port
                PublicIp = $_.PublicIp
                PublicPort = $_.PublicPort
                LocalLBVservers = $_.DiscoveryLoadBalancingVservers -join ', '
            }
        })
    Add-NetScalerTextTable -Report $report -Rows $gslbMemberRows -Columns ServiceGroup, Address, Port, PublicIp, PublicPort, LocalLBVservers -MaxRows $MaxRowsPerSection
    Add-NetScalerRawCommands -Report $report -Commands @($Dependency.GslbServiceGroupMembers | ForEach-Object { $_.Line }) -MaxRows $MaxRowsPerSection

    $report.Add('')
    $report.Add('GSLB service-group configuration')
    $report.Add('--------------------------------')
    $report.Add('Definitions and service types for the discovered global service groups.')
    Add-NetScalerTextTable -Report $report -Rows @($Dependency.GslbServiceGroups) -Columns Name, ServiceType -MaxRows $MaxRowsPerSection
    Add-NetScalerRawCommands -Report $report -Commands @($Dependency.GslbServiceGroups | ForEach-Object { $_.Line }) -MaxRows $MaxRowsPerSection

    $report.Add('')
    $report.Add('GSLB health monitors')
    $report.Add('--------------------')
    $report.Add('Health checks and monitor settings attached to discovered global service groups.')
    Add-NetScalerTextTable -Report $report -Rows @($Dependency.GslbMonitors) -Columns Name, Type -MaxRows $MaxRowsPerSection
    $report.Add('GSLB monitor configuration:')
    Add-NetScalerBoundedLines -Report $report -Lines @($Dependency.GslbMonitorConfiguration | ForEach-Object { $_.Line }) -MaxRows $MaxRowsPerSection
    Add-NetScalerRawCommands -Report $report -Commands @($Dependency.GslbMonitorConfiguration | ForEach-Object { $_.Line }; $Dependency.GslbMonitorBindingLines) -MaxRows $MaxRowsPerSection

    $report.Add('')
    $report.Add('GSLB vServers')
    $report.Add('-------------')
    $report.Add('Global DNS-aware virtual servers that use the discovered GSLB service groups.')
    Add-NetScalerTextTable -Report $report -Rows @($Dependency.GslbVservers) -Columns Name, ServiceType, ServiceGroup -MaxRows $MaxRowsPerSection
    Add-NetScalerRawCommands -Report $report -Commands @($Dependency.GslbVservers | ForEach-Object { $_.Line; $_.BindingLine }) -MaxRows $MaxRowsPerSection

    $report.Add('')
    $report.Add('GSLB domains')
    $report.Add('------------')
    $report.Add('Domain names bound to discovered GSLB virtual servers.')
    Add-NetScalerTextTable -Report $report -Rows @($Dependency.GslbDomains) -Columns Vserver, Name -MaxRows $MaxRowsPerSection
    Add-NetScalerRawCommands -Report $report -Commands @($Dependency.GslbDomains | ForEach-Object { $_.Line }) -MaxRows $MaxRowsPerSection

    $report.Add('')
    $report.Add('Certificate bindings')
    $report.Add('--------------------')
    $report.Add('Certificate-key bindings on discovered local and content-switching virtual servers.')
    Add-NetScalerTextTable -Report $report -Rows @($Dependency.Certificates) -Columns Vserver, Certificate -MaxRows $MaxRowsPerSection
    Add-NetScalerRawCommands -Report $report -Commands @($Dependency.Certificates | ForEach-Object { $_.Line }) -MaxRows $MaxRowsPerSection

    $report.Add('')
    $report.Add('Relevant vServer bindings')
    $report.Add('-------------------------')
    $report.Add('Additional bindings associated with discovered local and content-switching virtual servers.')
    Add-NetScalerBoundedLines -Report $report -Lines @($Dependency.VserverBindings) -MaxRows $MaxRowsPerSection
    Add-NetScalerRawCommands -Report $report -Commands @($Dependency.VserverBindings) -MaxRows $MaxRowsPerSection

    $report.Add('')
    $report.Add('Unprocessed lines for all discovered objects')
    $report.Add('--------------------------------------------')
    $report.Add('Related commands retained for inspection because this report does not interpret them.')
    Add-NetScalerBoundedLines -Report $report -Lines @($Dependency.UnprocessedRelevantLines) -MaxRows $MaxRowsPerSection

    $report -join [Environment]::NewLine
}

function ConvertTo-NetScalerHtmlReport {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Dependency,

        [Parameter(Mandatory)]
        [string]$SourceConfigPath,

        [Parameter(Mandatory)]
        [int]$MaxRowsPerSection
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

        $rows = @($Items | Select-Object -First $MaxRowsPerSection | ForEach-Object -Process { & $Row $_ })
        if ($Items.Count -gt $MaxRowsPerSection) {
            $rows += "<tr><td colspan=""2"" class=""empty"">(showing first $MaxRowsPerSection of $($Items.Count) rows)</td></tr>"
        }

        $rows -join [Environment]::NewLine
    }

    function ConvertTo-HtmlRawCommands {
        param(
            [AllowEmptyCollection()]
            [object[]]$Commands
        )

        $uniqueCommands = @($Commands | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        if ($uniqueCommands.Count -eq 0) {
            return '<p class="raw empty">Raw commands interpreted: (none)</p>'
        }

        $displayCommands = @($uniqueCommands | Select-Object -First $MaxRowsPerSection | ForEach-Object { ConvertTo-HtmlText $_ })
        $truncationNotice = if ($uniqueCommands.Count -gt $MaxRowsPerSection) {
            "<p class=""empty"">(showing first $MaxRowsPerSection of $($uniqueCommands.Count) commands)</p>"
        }
        else {
            ''
        }

        "<details class=""raw""><summary>Raw commands interpreted ($($uniqueCommands.Count))</summary><pre>$($displayCommands -join [Environment]::NewLine)</pre>$truncationNotice</details>"
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
        "<tr><td><code>$(ConvertTo-HtmlText $configuration.Line)</code></td></tr>"
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
    $serverRawCommands = ConvertTo-HtmlRawCommands -Commands @($Dependency.Server.Line)
    $peerServerRawCommands = ConvertTo-HtmlRawCommands -Commands @($Dependency.PeerServers | ForEach-Object { $_.RawCommands })
    $serviceRawCommands = ConvertTo-HtmlRawCommands -Commands @($Dependency.Services | ForEach-Object { $_.Line })
    $serviceGroupRawCommands = ConvertTo-HtmlRawCommands -Commands @($Dependency.ServiceGroups | ForEach-Object { $_.Line })
    $serviceGroupSslRawCommands = ConvertTo-HtmlRawCommands -Commands @($Dependency.ServiceGroupSslConfiguration | ForEach-Object { $_.Line })
    $monitorRawCommands = ConvertTo-HtmlRawCommands -Commands @($Dependency.Monitors | ForEach-Object { $_.Line }; $Dependency.MonitorBindingLines)
    $lbVserverRawCommands = ConvertTo-HtmlRawCommands -Commands @($Dependency.LoadBalancingVservers | ForEach-Object { $_.Line })
    $csVserverRawCommands = ConvertTo-HtmlRawCommands -Commands @($Dependency.ContentSwitchingVservers | ForEach-Object { $_.RawCommands })
    $gslbMemberRawCommands = ConvertTo-HtmlRawCommands -Commands @($Dependency.GslbServiceGroupMembers | ForEach-Object { $_.Line })
    $gslbServiceGroupRawCommands = ConvertTo-HtmlRawCommands -Commands @($Dependency.GslbServiceGroups | ForEach-Object { $_.Line })
    $gslbMonitorRawCommands = ConvertTo-HtmlRawCommands -Commands @($Dependency.GslbMonitorConfiguration | ForEach-Object { $_.Line }; $Dependency.GslbMonitorBindingLines)
    $gslbVserverRawCommands = ConvertTo-HtmlRawCommands -Commands @($Dependency.GslbVservers | ForEach-Object { $_.Line; $_.BindingLine })
    $gslbDomainRawCommands = ConvertTo-HtmlRawCommands -Commands @($Dependency.GslbDomains | ForEach-Object { $_.Line })
    $certificateRawCommands = ConvertTo-HtmlRawCommands -Commands @($Dependency.Certificates | ForEach-Object { $_.Line })
    $bindingRawCommands = ConvertTo-HtmlRawCommands -Commands @($Dependency.VserverBindings)

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
th { background: #f3f4f6; } code, pre { overflow-wrap: anywhere; white-space: pre-wrap; } .empty { color: #6b7280; font-style: italic; } .metadata { color: #4b5563; } .raw { margin: 0.75rem 0; } .raw summary { cursor: pointer; font-weight: 600; } .raw pre { background: #f9fafb; border: 1px solid #d1d5db; margin: 0.5rem 0; padding: 0.75rem; }
</style>
</head>
<body>
<h1>NetScaler server dependency report</h1>
<p class="metadata">Config: <code>$(ConvertTo-HtmlText $SourceConfigPath)</code></p>
<h2>Server</h2>
<p class="metadata">The backend server used as the starting point for the dependency walk.</p>
<table><thead><tr><th>Name</th><th>Address</th></tr></thead><tbody>
<tr><td>$(ConvertTo-HtmlText $Dependency.Server.Name)</td><td>$(ConvertTo-HtmlText $Dependency.Server.Address)</td></tr>
</tbody></table>
$serverRawCommands
<h2>Peer servers sharing a load-balancing vServer</h2>
<p class="metadata">Other backend servers that share a discovered local load-balancing vServer with the selected server.</p>
<table><thead><tr><th>Name</th><th>Address</th><th>Service</th><th>Shared LB vServer</th></tr></thead><tbody>$peerServerRows</tbody></table>
$peerServerRawCommands
<h2>Services</h2>
<p class="metadata">Direct service objects that point to the selected backend server.</p>
<table><thead><tr><th>Name</th><th>Protocol / port</th></tr></thead><tbody>$serviceRows</tbody></table>
$serviceRawCommands
<h2>Service groups</h2>
<p class="metadata">Load-balancing service groups that contain the selected backend server.</p>
<table><thead><tr><th>Name</th><th>Member port</th></tr></thead><tbody>$serviceGroupRows</tbody></table>
$serviceGroupRawCommands
<h2>Service-group SSL configuration</h2>
<p class="metadata">TLS configuration applied to the selected server service groups.</p>
<table><thead><tr><th>Configuration line</th></tr></thead><tbody>$serviceGroupSslRows</tbody></table>
$serviceGroupSslRawCommands
<h2>Health monitors</h2>
<p class="metadata">Health checks bound to the selected server services or service groups.</p>
<table><thead><tr><th>Name</th><th>Type</th></tr></thead><tbody>$monitorRows</tbody></table>
$monitorRawCommands
<h2>Load-balancing vServers</h2>
<p class="metadata">Local virtual IP endpoints that distribute traffic to the selected backend.</p>
<table><thead><tr><th>Name</th><th>VIP</th><th>Settings</th></tr></thead><tbody>$lbVserverRows</tbody></table>
$lbVserverRawCommands
<h2>Content-switching vServers</h2>
<p class="metadata">Front-end virtual servers that use policies to route requests to discovered load-balancing vServers.</p>
<table><thead><tr><th>Name</th><th>VIP</th><th>Route</th></tr></thead><tbody>$csVserverRows</tbody></table>
$csVserverRawCommands
<h2>GSLB service-group members</h2>
<p class="metadata">Global service endpoints correlated from discovered local load-balancing VIP and port pairs.</p>
<table><thead><tr><th>GSLB service group</th><th>Member endpoint</th><th>Public endpoint</th><th>Local LB vServers</th></tr></thead><tbody>$gslbMemberRows</tbody></table>
$gslbMemberRawCommands
<h2>GSLB service-group configuration</h2>
<p class="metadata">Definitions and service types for the discovered global service groups.</p>
<table><thead><tr><th>Name</th><th>Service type</th><th>Definition</th></tr></thead><tbody>$gslbServiceGroupRows</tbody></table>
$gslbServiceGroupRawCommands
<h2>GSLB health monitors</h2>
<p class="metadata">Health checks and monitor settings attached to discovered global service groups.</p>
<table><thead><tr><th>Name</th><th>Type</th></tr></thead><tbody>$gslbMonitorRows</tbody></table>
<table><thead><tr><th>Monitor configuration</th></tr></thead><tbody>$gslbMonitorConfigurationRows</tbody></table>
$gslbMonitorRawCommands
<h2>GSLB vServers</h2>
<p class="metadata">Global DNS-aware virtual servers that use the discovered GSLB service groups.</p>
<table><thead><tr><th>Name</th><th>Service type</th><th>GSLB service group</th></tr></thead><tbody>$gslbVserverRows</tbody></table>
$gslbVserverRawCommands
<h2>GSLB domains</h2>
<p class="metadata">Domain names bound to discovered GSLB virtual servers.</p>
<table><thead><tr><th>GSLB vServer</th><th>Domain name</th></tr></thead><tbody>$gslbDomainRows</tbody></table>
$gslbDomainRawCommands
<h2>Certificate bindings</h2>
<p class="metadata">Certificate-key bindings on discovered local and content-switching virtual servers.</p>
<table><thead><tr><th>vServer</th><th>Certificate</th></tr></thead><tbody>$certificateRows</tbody></table>
$certificateRawCommands
<h2>Relevant vServer bindings</h2>
<p class="metadata">Additional bindings associated with discovered local and content-switching virtual servers.</p>
<table><thead><tr><th>Binding</th></tr></thead><tbody>$bindingRows</tbody></table>
$bindingRawCommands
<h2>Unprocessed lines for all discovered objects</h2>
<p class="metadata">Related commands retained for inspection because this report does not interpret them.</p>
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
$serverDefinitionLines = @{}
foreach ($configuredServer in $allServers) {
    $serverAddresses[$configuredServer.Name] = $configuredServer.Address
    $serverDefinitionLines[$configuredServer.Name] = $configuredServer.Line
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
                    [pscustomobject]@{
                        Name                 = $member.Server
                        Address              = $serverAddresses[$member.Server]
                        Service              = $member.Name
                        LoadBalancingVserver = $serviceGroupBinding.Groups['Vserver'].Value
                        RawCommands          = @($serverDefinitionLines[$member.Server], $member.Line, $line)
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
                        RawCommands          = @($serverDefinitionLines[$member.Server], $member.Line, $line)
                    }
                }
        }
    }
) | Sort-Object Name, Service, LoadBalancingVserver -Unique

$csActionTargets = @{}
$csActionLines = @{}
foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*add\s+cs\s+action\s+(?<Action>\S+)\s+-targetLBVserver\s+(?<Vserver>\S+)', 'IgnoreCase')
    if ($match.Success) {
        $csActionTargets[$match.Groups['Action'].Value] = $match.Groups['Vserver'].Value
        $csActionLines[$match.Groups['Action'].Value] = $line
    }
}

$csPolicyActions = @{}
$csPolicyLines = @{}
foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*add\s+cs\s+policy\s+(?<Policy>\S+)\s+.*?-action\s+(?<Action>\S+)', 'IgnoreCase')
    if ($match.Success -and $csActionTargets.ContainsKey($match.Groups['Action'].Value) -and $csActionTargets[$match.Groups['Action'].Value] -in $lbVserverNames) {
        $csPolicyActions[$match.Groups['Policy'].Value] = $match.Groups['Action'].Value
        $csPolicyLines[$match.Groups['Policy'].Value] = $line
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
            RawCommands    = @($csVserverLine, $line, $csPolicyLines[$match.Groups['Policy'].Value], $csActionLines[$action])
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
    GslbMonitorBindingLines  = @($gslbMonitorBindingLines)
    Monitors                = @($monitors)
    MonitorBindingLines      = @($monitorBindingLines)
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
    if ([string]::IsNullOrWhiteSpace($HtmlOutputPath)) {
        $resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
        $safeServerName = $ServerName -replace '[<>:"/\\|?*]', '_'
        $HtmlOutputPath = Join-Path -Path (Split-Path -Parent $resolvedConfigPath) -ChildPath "dependency-report-$safeServerName.html"
    }

    ConvertTo-NetScalerHtmlReport -Dependency $result -SourceConfigPath $ConfigPath -MaxRowsPerSection $MaxRowsPerSection |
        Set-Content -LiteralPath $HtmlOutputPath -Encoding utf8
    "HTML report saved to: $HtmlOutputPath"
}
else {
    ConvertTo-NetScalerReport -Dependency $result -SourceConfigPath $ConfigPath -MaxRowsPerSection $MaxRowsPerSection
}
