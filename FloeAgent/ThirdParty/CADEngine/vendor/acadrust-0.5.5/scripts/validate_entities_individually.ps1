param(
    [string]$Root = 'target/entity-matrix-isolated',
    [string]$Atlas = 'target/entity-atlas',
    [string]$Version = 'AC1021',
    [ValidateSet('ACAD2027','BCAD')][string]$Engine = 'ACAD2027',
    [ValidateSet('dwg','dxf_ascii','dxf_binary')][string]$Format = 'dwg',
    [string]$Case = '*',
    [int]$TimeoutSeconds = 15,
    [switch]$Resume
)
$ErrorActionPreference = 'Stop'
function SharedHash([string]$Path) {
    $stream = [IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { [Convert]::ToHexString($algorithm.ComputeHash($stream)) } finally { $algorithm.Dispose(); $stream.Dispose() }
}
& cargo build --example entity_atlas --quiet
if ($LASTEXITCODE -ne 0) { throw 'Failed to build entity atlas' }
New-Item -ItemType Directory -Force -Path $Root | Out-Null
$generator = Join-Path ([IO.Path]::GetFullPath($Root)) "entity_atlas_$PID.exe"
Copy-Item -LiteralPath 'target/debug/examples/entity_atlas.exe' -Destination $generator -Force
$catalog = @(Get-Content (Join-Path $Atlas 'manifest.json') -Raw | ConvertFrom-Json)
$drawing = $catalog | Where-Object version -EQ $Version | Select-Object -First 1
if (-not $drawing) { throw "No atlas for $Version" }
foreach ($entity in $drawing.cases | Where-Object { $_.included -and $_.name -like $Case }) {
    $destination = Join-Path $Root $entity.name
    & $generator $destination "--case=$($entity.name)" "--version=$Version" --exact-case | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to generate $($entity.name)" }
    if ($Resume) {
        $name = "entity_atlas_${Version}_$Format"
        $resultPath = Join-Path $destination "validation/$Engine/$name/result.json"
        $drawingPath = Join-Path $destination "$Version/$name.$(if($Format -eq 'dwg'){'dwg'}else{'dxf'})"
        if (Test-Path -LiteralPath $resultPath) {
            $previous = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            if ($previous.source_sha256 -eq (SharedHash $drawingPath) -and
                $previous.status -ne 'ENGINE_STARTUP_FAILED' -and -not $previous.timed_out) {
                Write-Output "ENTITY $($entity.name): unchanged, $($previous.status)"
                continue
            }
        }
    }
    Write-Output "ENTITY $($entity.name)"
    & (Join-Path $PSScriptRoot 'validate_entity_atlas.ps1') -Root $destination -Engine $Engine -Filter "*_$Format" -TimeoutSeconds $TimeoutSeconds
}
