[CmdletBinding()]
param(
    [string]$Domain,
    [string]$Uuid,
    [string]$WsPath,
    [string]$EdgeA,
    [string]$EdgeB,
    [string]$EdgeC,
    [string]$InterfaceAlias,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'generated')
)
$ErrorActionPreference = 'Stop'
foreach ($field in @('Domain','Uuid','WsPath','EdgeA','EdgeB','EdgeC','InterfaceAlias')) {
    if ([string]::IsNullOrWhiteSpace((Get-Variable -Name $field -ValueOnly))) {
        Set-Variable -Name $field -Value (Read-Host "请输入 $field（含义见 README 参数表）")
    }
}
$Domain = $Domain.Trim().ToLowerInvariant()
$Uuid = $Uuid.Trim()
$WsPath = $WsPath.Trim()
$InterfaceAlias = $InterfaceAlias.Trim()
if ($Domain.Length -gt 253 -or $Domain -notmatch '^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$') {
    throw 'Domain 必须是域名，不含 https://、端口或路径。'
}
$parsedUuid = [guid]::Empty
if (-not [guid]::TryParse($Uuid, [ref]$parsedUuid)) { throw 'Uuid 不是有效 UUID。' }
$Uuid = $parsedUuid.ToString()
if ($WsPath -notmatch '^/[A-Za-z0-9_-]+$') { throw 'WsPath 应以 / 开头，后面只使用字母、数字、下划线或短横线。' }
$edges = @($EdgeA.Trim(), $EdgeB.Trim(), $EdgeC.Trim())
foreach ($edge in $edges) {
    $parsedIp = $null
    if (-not [Net.IPAddress]::TryParse($edge, [ref]$parsedIp) -or
        $parsedIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $parsedIp.ToString() -ne $edge) {
        throw "入口必须是标准 IPv4 地址：$edge"
    }
}
if (($edges | Select-Object -Unique).Count -ne 3) { throw '三个入口必须互不相同。' }
if ([string]::IsNullOrWhiteSpace($InterfaceAlias) -or $InterfaceAlias.Contains([string][char]13) -or $InterfaceAlias.Contains([string][char]10)) { throw '网卡名不能为空或包含换行。' }
if (Test-Path -LiteralPath $OutputDirectory) { throw '输出目录已存在，请另选 -OutputDirectory；本脚本不覆盖已有文件。' }
$utf8 = New-Object System.Text.UTF8Encoding($false)
$replacements = [ordered]@{
    '__DOMAIN__' = $Domain
    '__UUID__' = $Uuid
    '__WS_PATH__' = $WsPath
    '__EDGE_A__' = $edges[0]
    '__EDGE_B__' = $edges[1]
    '__EDGE_C__' = $edges[2]
    '__INTERFACE_YAML__' = ("'" + $InterfaceAlias.Replace("'", "''") + "'")
}
$server = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'templates\xray-server.json'), $utf8)
$windows = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'templates\mate-windows.yaml'), $utf8)
$android = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'templates\mate-android.yaml'), $utf8)
foreach ($entry in $replacements.GetEnumerator()) {
    $server = $server.Replace($entry.Key, $entry.Value)
    $windows = $windows.Replace($entry.Key, $entry.Value)
    $android = $android.Replace($entry.Key, $entry.Value)
}
foreach ($document in @($server, $windows, $android)) {
    if ($document -match '__[A-Z_]+__') { throw '存在未替换的占位符。' }
}
$null = $server | ConvertFrom-Json
$null = New-Item -ItemType Directory -Path $OutputDirectory
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'xray-server.json'), $server, $utf8)
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'mate-windows.yaml'), $windows, $utf8)
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'mate-android.yaml'), $android, $utf8)
Write-Host "生成完成：$OutputDirectory"
Write-Host '仅写入新目录；没有修改客户端设置、服务器、网络或防火墙。'
Write-Host '生成后的配置包含你自己的鉴权信息，请保管，不要公开分享 generated 目录。'
