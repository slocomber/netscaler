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

function Get-NetScalerOptionPairs {
    param(
        [Parameter(Mandatory)]
        [string]$Line
    )

    $matches = [regex]::Matches($Line, '(?i)(?:^|\s)-(?<Name>\S+)\s+(?:"(?<DoubleQuoted>[^"]*)"|''(?<SingleQuoted>[^'']*)''|(?<Value>\S+))')
    foreach ($match in $matches) {
        $value = if ($match.Groups['DoubleQuoted'].Success) {
            $match.Groups['DoubleQuoted'].Value
        }
        elseif ($match.Groups['SingleQuoted'].Success) {
            $match.Groups['SingleQuoted'].Value
        }
        else {
            $match.Groups['Value'].Value
        }

        [pscustomobject]@{
            Name = $match.Groups['Name'].Value
            Value = $value
        }
    }
}

function Get-UniqueSorted {
    param([object[]]$Items)

    @($Items | Where-Object { $null -ne $_ -and $_ -ne '' } | Sort-Object -Unique)
}

function Test-NetScalerDisabled {
    param([AllowNull()][string]$State)

    $State -ieq 'DISABLED'
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
    $serviceGroupRows = @($Dependency.ServiceGroups | Select-Object Name, Server, Port, State)
    Add-NetScalerTextTable -Report $report -Rows $serviceGroupRows -Columns Name, Server, Port, State -MaxRows $MaxRowsPerSection
    Add-NetScalerRawCommands -Report $report -Commands @($Dependency.ServiceGroups | ForEach-Object { $_.Line }) -MaxRows $MaxRowsPerSection

    $report.Add('')
    $report.Add('Service-group SSL configuration')
    $report.Add('-------------------------------')
    $report.Add('TLS configuration applied to the selected server service groups.')
    Add-NetScalerTextTable -Report $report -Rows @($Dependency.ServiceGroupSslConfiguration) -Columns ServiceGroup, Command, Purpose, Setting, Value -MaxRows $MaxRowsPerSection
    Add-NetScalerRawCommands -Report $report -Commands @($Dependency.ServiceGroupSslConfiguration | ForEach-Object { $_.Line }) -MaxRows $MaxRowsPerSection

    $report.Add('')
    $report.Add('Health monitors')
    $report.Add('---------------')
    $report.Add('Health checks bound to the selected server services or service groups.')
    Add-NetScalerTextTable -Report $report -Rows @($Dependency.Monitors) -Columns Name, Type, BoundTo -MaxRows $MaxRowsPerSection
    Add-NetScalerRawCommands -Report $report -Commands @($Dependency.Monitors | ForEach-Object { $_.Line }; $Dependency.MonitorBindingLines) -MaxRows $MaxRowsPerSection

    $report.Add('')
    $report.Add('Load-balancing vServers')
    $report.Add('------------------------')
    $report.Add('Local virtual IP endpoints that distribute traffic to the selected backend.')
    Add-NetScalerTextTable -Report $report -Rows @($Dependency.LoadBalancingVservers) -Columns Name, Protocol, Address, Port -MaxRows $MaxRowsPerSection
    $report.Add('Explicit vServer configuration:')
    Add-NetScalerTextTable -Report $report -Rows @($Dependency.LoadBalancingVserverConfiguration) -Columns Vserver, Command, Purpose, Setting, Value -MaxRows $MaxRowsPerSection
    Add-NetScalerRawCommands -Report $report -Commands @($Dependency.LoadBalancingVservers | ForEach-Object { $_.Line }; $Dependency.LoadBalancingVserverConfiguration | ForEach-Object { $_.Line }) -MaxRows $MaxRowsPerSection

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
    Add-NetScalerTextTable -Report $report -Rows @($Dependency.GslbMonitors) -Columns Name, Type, BoundTo -MaxRows $MaxRowsPerSection
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
    Add-NetScalerTextTable -Report $report -Rows @($Dependency.VserverBindingDetails) -Columns Vserver, VserverType, BindingType, Target, Priority, State -MaxRows $MaxRowsPerSection
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
        $rowClass = if ($service.IsDisabled) { ' class="disabled"' } else { '' }
        "<tr$rowClass><td>$(ConvertTo-HtmlText $service.Name)</td><td>$(ConvertTo-HtmlText $service.Protocol)</td><td>$(ConvertTo-HtmlText $service.Port)</td></tr>"
    }
    $serviceGroupRows = ConvertTo-HtmlRows -Items @($Dependency.ServiceGroups) -Row {
        param($serviceGroup)
        $port = if ($null -eq $serviceGroup.Port) { '' } else { $serviceGroup.Port }
        $rowClass = if ($serviceGroup.IsDisabled) { ' class="disabled"' } else { '' }
        "<tr$rowClass><td>$(ConvertTo-HtmlText $serviceGroup.Name)</td><td>$(ConvertTo-HtmlText $port)</td><td>$(ConvertTo-HtmlText $serviceGroup.State)</td></tr>"
    }
    $serviceGroupSslRows = ConvertTo-HtmlRows -Items @($Dependency.ServiceGroupSslConfiguration) -Row {
        param($sslConfiguration)
        $rowClass = if ($sslConfiguration.IsDisabled) { ' class="disabled"' } else { '' }
        "<tr$rowClass><td>$(ConvertTo-HtmlText $sslConfiguration.ServiceGroup)</td><td>$(ConvertTo-HtmlText $sslConfiguration.Command)</td><td>$(ConvertTo-HtmlText $sslConfiguration.Purpose)</td><td>$(ConvertTo-HtmlText $sslConfiguration.Setting)</td><td>$(ConvertTo-HtmlText $sslConfiguration.Value)</td></tr>"
    }
    $monitorRows = ConvertTo-HtmlRows -Items @($Dependency.Monitors) -Row {
        param($monitor)
        "<tr><td>$(ConvertTo-HtmlText $monitor.Name)</td><td>$(ConvertTo-HtmlText $monitor.Type)</td><td>$(ConvertTo-HtmlText $monitor.BoundTo)</td></tr>"
    }
    $lbVserverRows = ConvertTo-HtmlRows -Items @($Dependency.LoadBalancingVservers) -Row {
        param($vserver)
        $rowClass = if ($vserver.IsDisabled) { ' class="disabled"' } else { '' }
        "<tr$rowClass><td>$(ConvertTo-HtmlText $vserver.Name)</td><td>$(ConvertTo-HtmlText $vserver.Protocol)</td><td>$(ConvertTo-HtmlText $vserver.Address)</td><td>$(ConvertTo-HtmlText $vserver.Port)</td></tr>"
    }
    $lbVserverConfigurationRows = ConvertTo-HtmlRows -Items @($Dependency.LoadBalancingVserverConfiguration) -Row {
        param($configuration)
        $rowClass = if ($configuration.IsDisabled) { ' class="disabled"' } else { '' }
        "<tr$rowClass><td>$(ConvertTo-HtmlText $configuration.Vserver)</td><td>$(ConvertTo-HtmlText $configuration.Command)</td><td>$(ConvertTo-HtmlText $configuration.Purpose)</td><td>$(ConvertTo-HtmlText $configuration.Setting)</td><td>$(ConvertTo-HtmlText $configuration.Value)</td></tr>"
    }
    $csVserverRows = ConvertTo-HtmlRows -Items @($Dependency.ContentSwitchingVservers) -Row {
        param($vserver)
        $rowClass = if ($vserver.IsDisabled) { ' class="disabled"' } else { '' }
        "<tr$rowClass><td>$(ConvertTo-HtmlText $vserver.Name)</td><td>$(ConvertTo-HtmlText $vserver.Protocol)</td><td>$(ConvertTo-HtmlText $vserver.Address)</td><td>$(ConvertTo-HtmlText $vserver.Port)</td><td>$(ConvertTo-HtmlText $vserver.Policy)</td><td>$(ConvertTo-HtmlText $vserver.Action)</td><td>$(ConvertTo-HtmlText $vserver.TargetLBVserver)</td></tr>"
    }
    $gslbMemberRows = ConvertTo-HtmlRows -Items @($Dependency.GslbServiceGroupMembers) -Row {
        param($member)
        $publicEndpoint = if ($member.PublicIp -and $member.PublicPort) { "$($member.PublicIp):$($member.PublicPort)" } elseif ($member.PublicIp) { $member.PublicIp } else { '' }
        $rowClass = if ($member.IsDisabled) { ' class="disabled"' } else { '' }
        "<tr$rowClass><td>$(ConvertTo-HtmlText $member.GslbServiceGroup)</td><td>$(ConvertTo-HtmlText "$($member.Address):$($member.Port)")</td><td>$(ConvertTo-HtmlText $publicEndpoint)</td><td>$(ConvertTo-HtmlText ($member.DiscoveryLoadBalancingVservers -join ', '))</td></tr>"
    }
    $gslbServiceGroupRows = ConvertTo-HtmlRows -Items @($Dependency.GslbServiceGroups) -Row {
        param($serviceGroup)
        $rowClass = if ($serviceGroup.IsDisabled) { ' class="disabled"' } else { '' }
        "<tr$rowClass><td>$(ConvertTo-HtmlText $serviceGroup.Name)</td><td>$(ConvertTo-HtmlText $serviceGroup.ServiceType)</td></tr>"
    }
    $gslbVserverRows = ConvertTo-HtmlRows -Items @($Dependency.GslbVservers) -Row {
        param($vserver)
        $rowClass = if ($vserver.IsDisabled) { ' class="disabled"' } else { '' }
        "<tr$rowClass><td>$(ConvertTo-HtmlText $vserver.Name)</td><td>$(ConvertTo-HtmlText $vserver.ServiceType)</td><td>$(ConvertTo-HtmlText $vserver.ServiceGroup)</td></tr>"
    }
    $gslbDomainRows = ConvertTo-HtmlRows -Items @($Dependency.GslbDomains) -Row {
        param($domain)
        $rowClass = if ($domain.IsDisabled) { ' class="disabled"' } else { '' }
        "<tr$rowClass><td>$(ConvertTo-HtmlText $domain.Vserver)</td><td>$(ConvertTo-HtmlText $domain.Name)</td></tr>"
    }
    $gslbMonitorRows = ConvertTo-HtmlRows -Items @($Dependency.GslbMonitors) -Row {
        param($monitor)
        "<tr><td>$(ConvertTo-HtmlText $monitor.Name)</td><td>$(ConvertTo-HtmlText $monitor.Type)</td><td>$(ConvertTo-HtmlText $monitor.BoundTo)</td></tr>"
    }
    $gslbMonitorConfigurationRows = ConvertTo-HtmlRows -Items @($Dependency.GslbMonitorConfiguration) -Row {
        param($configuration)
        "<tr><td><code>$(ConvertTo-HtmlText $configuration.Line)</code></td></tr>"
    }
    $certificateRows = ConvertTo-HtmlRows -Items @($Dependency.Certificates) -Row {
        param($certificate)
        $rowClass = if ($certificate.IsDisabled) { ' class="disabled"' } else { '' }
        "<tr$rowClass><td>$(ConvertTo-HtmlText $certificate.Vserver)</td><td>$(ConvertTo-HtmlText $certificate.Certificate)</td></tr>"
    }
    $bindingRows = ConvertTo-HtmlRows -Items @($Dependency.VserverBindingDetails) -Row {
        param($binding)
        "<tr><td>$(ConvertTo-HtmlText $binding.Vserver)</td><td>$(ConvertTo-HtmlText $binding.VserverType)</td><td>$(ConvertTo-HtmlText $binding.BindingType)</td><td>$(ConvertTo-HtmlText $binding.Target)</td><td>$(ConvertTo-HtmlText $binding.Priority)</td><td>$(ConvertTo-HtmlText $binding.State)</td></tr>"
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
    $lbVserverRawCommands = ConvertTo-HtmlRawCommands -Commands @($Dependency.LoadBalancingVservers | ForEach-Object { $_.Line }; $Dependency.LoadBalancingVserverConfiguration | ForEach-Object { $_.Line })
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
th { background: #f3f4f6; } code, pre { overflow-wrap: anywhere; white-space: pre-wrap; } .empty { color: #6b7280; font-style: italic; } .metadata { color: #4b5563; } .raw { margin: 0.75rem 0; } .raw summary { cursor: pointer; font-weight: 600; } .raw pre { background: #f9fafb; border: 1px solid #d1d5db; margin: 0.5rem 0; padding: 0.75rem; } tr.disabled td { background: #f3f4f6; color: #6b7280; } tr.disabled code { color: #6b7280; }
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
<table><thead><tr><th>Name</th><th>Protocol</th><th>Port</th></tr></thead><tbody>$serviceRows</tbody></table>
$serviceRawCommands
<h2>Service groups</h2>
<p class="metadata">Load-balancing service groups that contain the selected backend server.</p>
<table><thead><tr><th>Name</th><th>Member port</th><th>State</th></tr></thead><tbody>$serviceGroupRows</tbody></table>
$serviceGroupRawCommands
<h2>Service-group SSL configuration</h2>
<p class="metadata">TLS configuration applied to the selected server service groups.</p>
<table><thead><tr><th>Service group</th><th>Command</th><th>Purpose</th><th>Setting</th><th>Value</th></tr></thead><tbody>$serviceGroupSslRows</tbody></table>
$serviceGroupSslRawCommands
<h2>Health monitors</h2>
<p class="metadata">Health checks bound to the selected server services or service groups.</p>
<table><thead><tr><th>Name</th><th>Type</th><th>Bound to</th></tr></thead><tbody>$monitorRows</tbody></table>
$monitorRawCommands
<h2>Load-balancing vServers</h2>
<p class="metadata">Local virtual IP endpoints that distribute traffic to the selected backend.</p>
<table><thead><tr><th>Name</th><th>Protocol</th><th>Address</th><th>Port</th></tr></thead><tbody>$lbVserverRows</tbody></table>
<table><thead><tr><th>Virtual server</th><th>Command</th><th>Purpose</th><th>Setting</th><th>Value</th></tr></thead><tbody>$lbVserverConfigurationRows</tbody></table>
$lbVserverRawCommands
<h2>Content-switching vServers</h2>
<p class="metadata">Front-end virtual servers that use policies to route requests to discovered load-balancing vServers.</p>
<table><thead><tr><th>Name</th><th>Protocol</th><th>Address</th><th>Port</th><th>Policy</th><th>Action</th><th>Target LB vServer</th></tr></thead><tbody>$csVserverRows</tbody></table>
$csVserverRawCommands
<h2>GSLB service-group members</h2>
<p class="metadata">Global service endpoints correlated from discovered local load-balancing VIP and port pairs.</p>
<table><thead><tr><th>GSLB service group</th><th>Member endpoint</th><th>Public endpoint</th><th>Local LB vServers</th></tr></thead><tbody>$gslbMemberRows</tbody></table>
$gslbMemberRawCommands
<h2>GSLB service-group configuration</h2>
<p class="metadata">Definitions and service types for the discovered global service groups.</p>
<table><thead><tr><th>Name</th><th>Service type</th></tr></thead><tbody>$gslbServiceGroupRows</tbody></table>
$gslbServiceGroupRawCommands
<h2>GSLB health monitors</h2>
<p class="metadata">Health checks and monitor settings attached to discovered global service groups.</p>
<table><thead><tr><th>Name</th><th>Type</th><th>Bound to service group</th></tr></thead><tbody>$gslbMonitorRows</tbody></table>
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
<table><thead><tr><th>vServer</th><th>Type</th><th>Binding type</th><th>Target</th><th>Priority</th><th>State</th></tr></thead><tbody>$bindingRows</tbody></table>
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
            State    = Get-NetScalerOption -Line $line -Name 'state'
            IsDisabled = Test-NetScalerDisabled (Get-NetScalerOption -Line $line -Name 'state')
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
            State = Get-NetScalerOption -Line $line -Name 'state'
            IsDisabled = Test-NetScalerDisabled (Get-NetScalerOption -Line $line -Name 'state')
            Line = $line
        }
    }
}
$serviceGroupMembers = @($allServiceGroupMembers | Where-Object { $_.Server -ieq $server[0].Name })

$serviceNames = Get-UniqueSorted @($services | ForEach-Object { $_.Name })
$serviceGroupNames = Get-UniqueSorted @($serviceGroupMembers | ForEach-Object { $_.Name })
$disabledServiceGroupNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($serviceGroupMember in $serviceGroupMembers) {
    if ($serviceGroupMember.IsDisabled) {
        [void]$disabledServiceGroupNames.Add($serviceGroupMember.Name)
    }
}

$serviceGroupSslConfiguration = foreach ($line in $lines) {
    $serviceGroupDefinition = [regex]::Match($line, '^\s*add\s+serviceGroup\s+(?<Group>\S+)\s+(?<ServiceType>\S+)', 'IgnoreCase')
    if ($serviceGroupDefinition.Success -and $serviceGroupDefinition.Groups['Group'].Value -in $serviceGroupNames) {
        [pscustomobject]@{
            ServiceGroup = $serviceGroupDefinition.Groups['Group'].Value
            Command      = 'add'
            Purpose      = 'Defines the service group and its service type.'
            Setting      = 'serviceType'
            Value        = $serviceGroupDefinition.Groups['ServiceType'].Value
            IsDisabled   = $disabledServiceGroupNames.Contains($serviceGroupDefinition.Groups['Group'].Value)
            Line         = $line
        }
        continue
    }

    $sslConfiguration = [regex]::Match($line, '^\s*(?<Command>set|bind)\s+ssl\s+serviceGroup\s+(?<Group>\S+)', 'IgnoreCase')
    if ($sslConfiguration.Success -and $sslConfiguration.Groups['Group'].Value -in $serviceGroupNames) {
        foreach ($option in (Get-NetScalerOptionPairs -Line $line)) {
            [pscustomobject]@{
                ServiceGroup = $sslConfiguration.Groups['Group'].Value
                Command      = $sslConfiguration.Groups['Command'].Value.ToLowerInvariant()
                Purpose      = if ($sslConfiguration.Groups['Command'].Value -ieq 'set') {
                    'Sets an SSL/TLS property for the service group.'
                }
                else {
                    'Binds an SSL/TLS resource to the service group.'
                }
                Setting      = $option.Name
                Value        = $option.Value
                IsDisabled   = $disabledServiceGroupNames.Contains($sslConfiguration.Groups['Group'].Value)
                Line         = $line
            }
        }
    }
}

$monitorBindings = @(
    foreach ($line in $lines) {
        $match = [regex]::Match($line, '^\s*bind\s+service\s+(?<Service>\S+)\s+-monitorName\s+(?<Monitor>\S+)', 'IgnoreCase')
        if ($match.Success -and $match.Groups['Service'].Value -in $serviceNames) {
            [pscustomobject]@{
                Monitor = $match.Groups['Monitor'].Value
                BoundTo = "service $($match.Groups['Service'].Value)"
                Line    = $line
            }
        }

        $match = [regex]::Match($line, '^\s*bind\s+serviceGroup\s+(?<Group>\S+)\s+-monitorName\s+(?<Monitor>\S+)', 'IgnoreCase')
        if ($match.Success -and $match.Groups['Group'].Value -in $serviceGroupNames) {
            [pscustomobject]@{
                Monitor = $match.Groups['Monitor'].Value
                BoundTo = "service group $($match.Groups['Group'].Value)"
                Line    = $line
            }
        }
    }
)
$monitorBindingLines = @($monitorBindings | ForEach-Object { $_.Line })
$monitorNames = Get-UniqueSorted @($monitorBindings | ForEach-Object { $_.Monitor })
$monitorTargetsByName = @{}
foreach ($binding in $monitorBindings) {
    if (-not $monitorTargetsByName.ContainsKey($binding.Monitor)) {
        $monitorTargetsByName[$binding.Monitor] = [System.Collections.Generic.List[string]]::new()
    }
    $monitorTargetsByName[$binding.Monitor].Add($binding.BoundTo)
}

$monitors = foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*add\s+lb\s+monitor\s+(?<Name>\S+)\s+(?<Type>\S+)', 'IgnoreCase')
    if ($match.Success -and $match.Groups['Name'].Value -in $monitorNames) {
        [pscustomobject]@{
            Name    = $match.Groups['Name'].Value
            Type    = $match.Groups['Type'].Value
            BoundTo = (Get-UniqueSorted @($monitorTargetsByName[$match.Groups['Name'].Value]) -join ', ')
            Line    = $line
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
            State      = Get-NetScalerOption -Line $line -Name 'state'
            IsDisabled = Test-NetScalerDisabled (Get-NetScalerOption -Line $line -Name 'state')
            Line       = $line
        }
    }
}
$lbVserverConfiguration = @(
    foreach ($vserver in $lbVservers) {
        foreach ($option in (Get-NetScalerOptionPairs -Line $vserver.Line)) {
            [pscustomobject]@{
                Vserver = $vserver.Name
                Command = 'add'
                Purpose = 'Creates the vServer with the listed option.'
                Setting = $option.Name
                Value   = $option.Value
                IsDisabled = $false
                Line    = $vserver.Line
            }
        }
    }

    foreach ($line in $lines) {
        $match = [regex]::Match($line, '^\s*set\s+lb\s+vserver\s+(?<Vserver>\S+)', 'IgnoreCase')
        if ($match.Success -and $match.Groups['Vserver'].Value -in $lbVserverNames) {
            foreach ($option in (Get-NetScalerOptionPairs -Line $line)) {
                [pscustomobject]@{
                    Vserver = $match.Groups['Vserver'].Value
                    Command = 'set'
                    Purpose = 'Updates a vServer option.'
                    Setting = $option.Name
                    Value   = $option.Value
                    IsDisabled = $false
                    Line    = $line
                }
            }
        }
    }
)
$lbVserversByName = @{}
foreach ($vserver in $lbVservers) {
    $lbVserversByName[$vserver.Name] = $vserver
}
foreach ($configuration in $lbVserverConfiguration) {
    if ($configuration.Setting -ieq 'state') {
        $lbVserversByName[$configuration.Vserver].State = $configuration.Value
    }
}
foreach ($vserver in $lbVservers) {
    $vserver.IsDisabled = Test-NetScalerDisabled $vserver.State
}
foreach ($configuration in $lbVserverConfiguration) {
    $configuration.IsDisabled = $lbVserversByName[$configuration.Vserver].IsDisabled
}
$lbVserversByEndpoint = @{}
foreach ($vserver in $lbVservers) {
    $endpointKey = "$($vserver.Address)|$($vserver.Port)"
    if (-not $lbVserversByEndpoint.ContainsKey($endpointKey)) {
        $lbVserversByEndpoint[$endpointKey] = [System.Collections.Generic.List[string]]::new()
    }
    $lbVserversByEndpoint[$endpointKey].Add($vserver.Name)
}

$gslbServiceGroupDiscoveries = @(
    foreach ($line in $lines) {
        $match = [regex]::Match($line, '^\s*bind\s+gslb\s+serviceGroup\s+(?<Group>\S+)\s+(?<Address>\S+)\s+(?<Port>\d+)', 'IgnoreCase')
        if ($match.Success) {
            $endpointKey = "$($match.Groups['Address'].Value)|$([int]$match.Groups['Port'].Value)"
            $matchingVservers = @(
                if ($lbVserversByEndpoint.ContainsKey($endpointKey)) {
                    $lbVserversByEndpoint[$endpointKey]
                }
            )
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
$gslbServiceGroupBindingLines = foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*bind\s+gslb\s+serviceGroup\s+(?<Group>\S+)', 'IgnoreCase')
    if ($match.Success -and $match.Groups['Group'].Value -in $gslbServiceGroupNames) {
        $line
    }
}

$gslbServiceGroups = foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*add\s+gslb\s+serviceGroup\s+(?<Name>\S+)\s+(?<ServiceType>\S+)', 'IgnoreCase')
    if ($match.Success -and $match.Groups['Name'].Value -in $gslbServiceGroupNames) {
        [pscustomobject]@{
            Name        = $match.Groups['Name'].Value
            ServiceType = $match.Groups['ServiceType'].Value
            State       = Get-NetScalerOption -Line $line -Name 'state'
            IsDisabled  = Test-NetScalerDisabled (Get-NetScalerOption -Line $line -Name 'state')
            Line        = $line
        }
    }
}
$gslbServiceGroupsByName = @{}
foreach ($serviceGroup in $gslbServiceGroups) {
    $gslbServiceGroupsByName[$serviceGroup.Name] = $serviceGroup
}

$gslbServiceGroupMembers = foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*bind\s+gslb\s+serviceGroup\s+(?<Group>\S+)\s+(?<Address>\S+)\s+(?<Port>\d+)', 'IgnoreCase')
    if ($match.Success -and $match.Groups['Group'].Value -in $gslbServiceGroupNames) {
        $endpointKey = "$($match.Groups['Address'].Value)|$([int]$match.Groups['Port'].Value)"
        [pscustomobject]@{
            GslbServiceGroup                = $match.Groups['Group'].Value
            Address                         = $match.Groups['Address'].Value
            Port                            = [int]$match.Groups['Port'].Value
            PublicIp                        = Get-NetScalerOption -Line $line -Name 'publicIP'
            PublicPort                      = Get-NetScalerOption -Line $line -Name 'publicPort'
            State                            = Get-NetScalerOption -Line $line -Name 'state'
            IsDisabled                       = (Test-NetScalerDisabled (Get-NetScalerOption -Line $line -Name 'state')) -or $gslbServiceGroupsByName[$match.Groups['Group'].Value].IsDisabled
            DiscoveryLoadBalancingVservers  = if ($lbVserversByEndpoint.ContainsKey($endpointKey)) {
                Get-UniqueSorted @($lbVserversByEndpoint[$endpointKey])
            }
            else {
                @()
            }
            Line                            = $line
        }
    }
}

$gslbVserverDefinitionsByName = @{}
foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*add\s+gslb\s+vserver\s+(?<Name>\S+)\s+(?<ServiceType>\S+)', 'IgnoreCase')
    if ($match.Success) {
        $gslbVserverDefinitionsByName[$match.Groups['Name'].Value] = $line
    }
}
$gslbVserverBindings = foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*bind\s+gslb\s+vserver\s+(?<Vserver>\S+)', 'IgnoreCase')
    $serviceGroupName = if ($match.Success) { Get-NetScalerOption -Line $line -Name 'serviceGroupName' } else { $null }
    if ($match.Success -and $serviceGroupName -in $gslbServiceGroupNames) {
        [pscustomobject]@{ Name = $match.Groups['Vserver'].Value; ServiceGroup = $serviceGroupName; BindingLine = $line }
    }
}

$gslbVservers = foreach ($binding in $gslbVserverBindings) {
    $definitionLine = $gslbVserverDefinitionsByName[$binding.Name]
    $definition = if ($definitionLine) { [regex]::Match($definitionLine, '^\s*add\s+gslb\s+vserver\s+(?<Name>\S+)\s+(?<ServiceType>\S+)', 'IgnoreCase') }
    [pscustomobject]@{
        Name = $binding.Name
        ServiceType = if ($null -ne $definition -and $definition.Success) { $definition.Groups['ServiceType'].Value } else { $null }
        ServiceGroup = $binding.ServiceGroup
        BindingLine = $binding.BindingLine
        Line = $definitionLine
        State = if ($definitionLine) { Get-NetScalerOption -Line $definitionLine -Name 'state' } else { $null }
        IsDisabled = if ($definitionLine) { Test-NetScalerDisabled (Get-NetScalerOption -Line $definitionLine -Name 'state') } else { $false }
    }
}

$gslbVserverNames = Get-UniqueSorted @($gslbVservers | ForEach-Object { $_.Name })
$gslbVserversByName = @{}
foreach ($vserver in $gslbVservers) {
    $gslbVserversByName[$vserver.Name] = $vserver
}
$gslbDomains = foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*bind\s+gslb\s+vserver\s+(?<Vserver>\S+)\s+-domainName\s+(?<Domain>\S+)', 'IgnoreCase')
    if ($match.Success -and $match.Groups['Vserver'].Value -in $gslbVserverNames) {
        [pscustomobject]@{
            Vserver = $match.Groups['Vserver'].Value
            Name    = $match.Groups['Domain'].Value
            IsDisabled = $gslbVserversByName[$match.Groups['Vserver'].Value].IsDisabled
            Line    = $line
        }
    }
}

$gslbMonitorBindings = @(
    foreach ($line in $lines) {
        $match = [regex]::Match($line, '^\s*bind\s+gslb\s+serviceGroup\s+(?<Group>\S+)\s+-monitorName\s+(?<Monitor>\S+)', 'IgnoreCase')
        if ($match.Success -and $match.Groups['Group'].Value -in $gslbServiceGroupNames) {
            [pscustomobject]@{
                Monitor      = $match.Groups['Monitor'].Value
                ServiceGroup = $match.Groups['Group'].Value
                Line         = $line
            }
        }
    }
)
$gslbMonitorBindingLines = @($gslbMonitorBindings | ForEach-Object { $_.Line })
$gslbMonitorNames = Get-UniqueSorted @($gslbMonitorBindings | ForEach-Object { $_.Monitor })
$gslbMonitorGroupsByName = @{}
foreach ($binding in $gslbMonitorBindings) {
    if (-not $gslbMonitorGroupsByName.ContainsKey($binding.Monitor)) {
        $gslbMonitorGroupsByName[$binding.Monitor] = [System.Collections.Generic.List[string]]::new()
    }
    $gslbMonitorGroupsByName[$binding.Monitor].Add($binding.ServiceGroup)
}
$gslbMonitors = foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*add\s+lb\s+monitor\s+(?<Name>\S+)\s+(?<Type>\S+)', 'IgnoreCase')
    if ($match.Success -and $match.Groups['Name'].Value -in $gslbMonitorNames) {
        [pscustomobject]@{
            Name    = $match.Groups['Name'].Value
            Type    = $match.Groups['Type'].Value
            BoundTo = (Get-UniqueSorted @($gslbMonitorGroupsByName[$match.Groups['Name'].Value]) -join ', ')
            Line    = $line
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
            State          = Get-NetScalerOption -Line $csVserverLine -Name 'state'
            IsDisabled     = Test-NetScalerDisabled (Get-NetScalerOption -Line $csVserverLine -Name 'state')
            RawCommands    = @($csVserverLine, $line, $csPolicyLines[$match.Groups['Policy'].Value], $csActionLines[$action])
        }
    }
}

$vserverNames = Get-UniqueSorted @(
    $lbVservers | ForEach-Object { $_.Name }
    $contentSwitchingVservers | ForEach-Object { $_.Name }
)
$vserversByName = @{}
foreach ($vserver in @($lbVservers) + @($contentSwitchingVservers)) {
    $vserversByName[$vserver.Name] = $vserver
}
$vserverBindings = foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*bind\s+(?:lb|cs)\s+vserver\s+(?<Vserver>\S+)', 'IgnoreCase')
    if ($match.Success -and $match.Groups['Vserver'].Value -in $vserverNames) {
        $line
    }
}
$vserverBindingDetails = foreach ($line in $vserverBindings) {
    $match = [regex]::Match($line, '^\s*bind\s+(?<VserverType>lb|cs)\s+vserver\s+(?<Vserver>\S+)(?:\s+(?<PositionalTarget>(?!-)\S+))?', 'IgnoreCase')
    $serviceName = Get-NetScalerOption -Line $line -Name 'serviceName'
    $serviceGroupName = Get-NetScalerOption -Line $line -Name 'serviceGroupName'
    $policyName = Get-NetScalerOption -Line $line -Name 'policyName'
    $positionalTarget = $match.Groups['PositionalTarget'].Value

    $bindingType = 'other'
    $target = ''
    if ($serviceName) {
        $bindingType = 'service'
        $target = $serviceName
    }
    elseif ($serviceGroupName) {
        $bindingType = 'service group'
        $target = $serviceGroupName
    }
    elseif ($policyName) {
        $bindingType = 'policy'
        $target = $policyName
    }
    elseif ($positionalTarget -in $serviceNames) {
        $bindingType = 'service'
        $target = $positionalTarget
    }
    elseif ($positionalTarget -in $serviceGroupNames) {
        $bindingType = 'service group'
        $target = $positionalTarget
    }
    elseif ($positionalTarget) {
        $bindingType = 'target'
        $target = $positionalTarget
    }

    [pscustomobject]@{
        Vserver     = $match.Groups['Vserver'].Value
        VserverType = $match.Groups['VserverType'].Value.ToUpperInvariant()
        BindingType = $bindingType
        Target      = $target
        Priority    = Get-NetScalerOption -Line $line -Name 'priority'
        State       = Get-NetScalerOption -Line $line -Name 'state'
        Line        = $line
    }
}

$certificateBindings = foreach ($line in $lines) {
    $match = [regex]::Match($line, '^\s*bind\s+ssl\s+vserver\s+(?<Vserver>\S+)\s+-certkeyName\s+(?<Certificate>\S+)', 'IgnoreCase')
    if ($match.Success -and $match.Groups['Vserver'].Value -in $vserverNames) {
        [pscustomobject]@{
            Vserver     = $match.Groups['Vserver'].Value
            Certificate = $match.Groups['Certificate'].Value
            IsDisabled  = $vserversByName[$match.Groups['Vserver'].Value].IsDisabled
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
        $lbVserverConfiguration
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
foreach ($binding in $gslbServiceGroupBindingLines) {
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
    LoadBalancingVserverConfiguration = @($lbVserverConfiguration)
    ContentSwitchingVservers = @($contentSwitchingVservers)
    Certificates            = @($certificateBindings)
    VserverBindings         = @($vserverBindings)
    VserverBindingDetails   = @($vserverBindingDetails)
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
