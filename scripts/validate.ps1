$ErrorActionPreference = 'Stop'
Push-Location (Join-Path $PSScriptRoot '..')
try {
    $serverJson = & docker compose --env-file .env.example -f compose.server.yml --profile '*' config --format json
    if ($LASTEXITCODE -ne 0) { throw 'Server Compose rendering failed.' }
    $piJson = & docker compose --env-file .env.example -f compose.pi.yml config --format json
    if ($LASTEXITCODE -ne 0) { throw 'Pi Compose rendering failed.' }
    $server = ($serverJson -join "`n") | ConvertFrom-Json
    $pi = ($piJson -join "`n") | ConvertFrom-Json

    function Assert($condition, $message) {
        if (-not $condition) { throw $message }
    }
    $expectedServer = @('unbound', 'adguard', 'caddy', 'mqtt', 'homeassistant', 'zigbee2mqtt', 'zwave', 'esphome', 'frigate', 'netalertx', 'forgejo', 'runner')
    Assert (@($server.services.PSObject.Properties).Count -eq $expectedServer.Count) 'Unexpected server service count.'
    foreach ($name in $expectedServer) {
        Assert ($null -ne $server.services.$name) "Missing server service: $name"
    }
    Assert (@($pi.services.PSObject.Properties).Count -eq 3) 'Expected three Pi services.'
    foreach ($model in @($server, $pi)) {
        foreach ($entry in $model.services.PSObject.Properties) {
            $service = $entry.Value
            Assert (-not $service.privileged) "$($entry.Name) must not be privileged."
            foreach ($volume in $service.volumes) {
                Assert ($volume.source -notmatch 'docker\.sock') 'Never mount the host Docker socket.'
            }
            foreach ($port in $service.ports) {
                Assert ($port.target -notin @(1883, 3000, 5000, 5335) -or $port.host_ip -eq '127.0.0.1') "Internal port exposed by $($entry.Name)."
                if ($entry.Name -ne 'adguard' -and $entry.Name -ne 'uptime-kuma') {
                    Assert ($port.host_ip -eq '127.0.0.1') "Non-loopback application port on $($entry.Name)."
                }
            }
        }
    }
    Assert (-not $server.services.mqtt.ports) 'MQTT must not publish ports.'
    Assert (-not $server.services.unbound.ports) 'Unbound must not publish ports.'
    Assert ($server.services.caddy.network_mode -eq 'host') 'Caddy must reach loopback backends.'
    $recordingMount = @($server.services.frigate.volumes | Where-Object { $_.target -eq '/media/frigate/recordings' })
    Assert ($recordingMount.Count -eq 1 -and -not $recordingMount[0].bind.create_host_path) 'Recording mount must not be created silently.'
    $marker = @($server.services.frigate.volumes | Where-Object { $_.target -eq '/run/homelab-recording-volume' })
    Assert ($marker.Count -eq 1 -and $marker[0].read_only -and -not $marker[0].bind.create_host_path) 'A missing recording disk must prevent automatic container startup.'
    Assert ($server.services.homeassistant.networks.PSObject.Properties.Name -contains 'default') 'HA must use the documented proxy network.'
    Assert ($server.networks.default.ipam.config[0].subnet -eq '172.28.0.0/24') 'HA trusted proxy must match the Docker gateway.'
    $zigbee = Get-Content -LiteralPath services\zigbee2mqtt\configuration.yaml -Raw
    Assert ($zigbee -match 'enable_external_js: false') 'External Zigbee JS must be disabled.'
    Assert ($zigbee -match 'permit_join: false') 'Zigbee pairing must default to closed.'
    $frigate = Get-Content -LiteralPath services\frigate\config.yml -Raw
    Assert (([regex]::Matches($frigate, '(?m)^  camera_[1-5]:')).Count -eq 5) 'Expected five cameras.'
    Write-Output 'PASS: both Compose models, service inventory, exposure, storage, and Zigbee safety invariants.'
} finally {
    Pop-Location
}
