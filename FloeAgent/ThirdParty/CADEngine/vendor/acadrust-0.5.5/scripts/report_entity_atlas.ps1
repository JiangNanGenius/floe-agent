param([string]$Root='target/entity-atlas',[string[]]$Engines=@('BCAD','ACAD2027'))
$ErrorActionPreference='Stop'
$rootPath=(Resolve-Path -LiteralPath $Root).Path
$manifest=@(Get-Content (Join-Path $rootPath 'manifest.json') -Raw | ConvertFrom-Json)
$engines=$Engines
$rows=@(foreach($engine in $engines){
    Get-ChildItem (Join-Path $rootPath "validation/$engine") -Recurse -File -Filter result.json -ErrorAction SilentlyContinue | ForEach-Object {Get-Content $_.FullName -Raw | ConvertFrom-Json}
})
$index=@{}
foreach($row in $rows){
    $copy=Join-Path $row.log_directory ([IO.Path]::GetFileName($row.file))
    $validatedHash=$row.source_sha256
    if(-not $validatedHash -and (Test-Path -LiteralPath $copy)){
        $validatedHash=(Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash
    }
    if(-not $validatedHash -or $validatedHash -ne (Get-FileHash -LiteralPath $row.file -Algorithm SHA256).Hash){
        $row.status='STALE_RESULT'
    }
    $index["$($row.engine)|$($row.version)|$($row.format)"]=$row
}
function Link([string]$Path){$Path.Replace('\','/').Replace(' ','%20')}
function Cell($Result){
    if($null -eq $Result){return 'Not run'}
    if($Result.status -eq 'STALE_RESULT'){return 'Not rerun after regeneration'}
    if(-not $Result.loaded){return 'Open failed/blocked'}
    if(-not $Result.completed){return 'Audit incomplete'}
    $audit=if($null -eq $Result.audit_errors){'audit unknown'}else{"$($Result.audit_errors) audit errors"}
    $unreadable=if($Result.unreadable_records -gt 0){"; $($Result.unreadable_records) unreadable"}else{''}
    $proxies=@($Result.records | Where-Object { $_.type -match 'PROXY' -and $_.layer -like 'E*' }).Count
    $proxyText=if($proxies -gt 0){"; $proxies proxies"}else{''}
    "$($Result.present_cases)/$($Result.expected_cases) cases; $audit$unreadable$proxyText"
}
$text=[Collections.Generic.List[string]]::new()
$text.Add('# Entity Atlas Compatibility Report')
$text.Add('')
$text.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')")
$text.Add('')
$text.Add('24 original drawings: eight supported versions, each as DWG, ASCII DXF, and binary DXF. Each drawing uses the same 71 numbered positions. Older versions omit ineligible entities and label their required version. All original drawings were tested through copies.')
$text.Add('')
$text.Add('BCAD: BricsCAD V20.1, accessed through its COM API from PowerShell with a per-file watchdog. ACAD2027: AutoCAD 2027.1 core console. IntelliCAD was excluded from the remaining work at the user''s request; its earlier logs are retained under validation/ICAD. No computer-use automation was used for this run.')
$text.Add('')
$text.Add('A case is present when the CAD database contains an entity on its E### layer. Presence does not prove a valid B-rep, native type, or correct rendering. Audit errors, proxy conversion, and missing cases remain failures. Block markers, vertices, and sequence ends are tested through their proper owners; external/proprietary payload exclusions and surface-fixture limitations are listed in [coverage notes](coverage-notes.md).')
$text.Add('')
$text.Add('| Version / File | '+($engines -join ' | ')+' |')
$text.Add('|---|'+((@('---') * $engines.Count) -join '|')+'|')
foreach($drawing in $manifest){
    $label="$($drawing.version) $($drawing.format)"
    $cells=@(foreach($engine in $engines){Cell $index["$engine|$($drawing.version)|$($drawing.format)"]})
    $text.Add(('| [{0}]({1}) | {2} |' -f $label,(Link $drawing.file),($cells -join ' | ')))
}
$text.Add('')
$text.Add('## Engine Totals')
$text.Add('')
foreach($engine in $engines){
    $set=@($rows|Where-Object { $_.engine -eq $engine -and $_.status -ne 'STALE_RESULT' })
    $loaded=@($set|Where-Object loaded).Count
    $finished=@($set|Where-Object completed).Count
    $pass=@($set|Where-Object status -EQ 'PASS').Count
    $text.Add("- ${engine}: $($set.Count)/24 current results, $loaded opened, $finished audits/scripts completed, $pass fully passing.")
}
$text.Add('')
$text.Add('## Findings')
$text.Add('')
$text.Add('- Repairs are documented in src/docs/entity_audit_2026_09_09.md. Current DXF atlases open with zero audit errors in AutoCAD, but proxy entities in older versions prevent full native compatibility passes.')
$text.Add('- Audit errors are counted without requesting repair. A zero-error audit is not a pass when cases disappeared during loading.')
$text.Add('- The library reads all 24 exports, but its own layer inventory also detects dropped class-based records in several DWG versions. The manifests preserve those observations.')
$text.Add('- Fresh one-LINE controls passed direct open and AUDIT in all eight versions in the completed IntelliCAD checks. AutoCAD passed AC1012, AC1014, AC1015, AC1018, AC1021, and AC1024; AC1027 and AC1032 failed with FilerError 53. Those control files and logs are in ../entity-atlas-minimal/. This does not establish that every rich drawing is recoverable or that its geometry is intact.')
$text.Add('- Remaining native DWG failures include advanced surface construction records and an independent AC1027/AC1032 opening issue even with a single LINE. DXF acceptance does not certify DWG output.')
$text.Add('- Native rendering was not visually verified: the requested continuation used console/COM checks only. The atlas is a reproduction corpus with known failures, not a compatibility-certified drawing set.')
$text.Add('')
$text.Add('## Missing Cases And Diagnostics')
$text.Add('')
foreach($row in ($rows|Sort-Object engine,version,format)){
    $text.Add("### $($row.engine) / $($row.version) / $($row.format)")
    $text.Add('')
    $text.Add("Status: $($row.status). [Full result and entity inventory]($(Link (Join-Path $row.log_directory 'result.json'))).")
    if($row.loaded -and $row.missing.Count -gt 0){$text.Add('Absent from inventory (may include unreadable records): '+($row.missing -join ', ')+'.')}
    if($row.unreadable_records -gt 0){$text.Add("Unreadable database records: $($row.unreadable_records). Their types/layers could not be verified.")}
    $proxy=@($row.cases|Where-Object {($_.actual_types -join ' ') -match 'Proxy'}|ForEach-Object name)
    if($proxy.Count -gt 0){$text.Add('Proxy cases: '+($proxy -join ', ')+'.')}
    $diagnostics=@($row.diagnostics|Select-Object -First 8)
    if($diagnostics.Count -gt 0){$text.Add('');$text.Add('```text');foreach($line in $diagnostics){$text.Add($line)};$text.Add('```')}
    $text.Add('')
}
$text.Add('## Reproduction')
$text.Add('')
$text.Add('```powershell')
$text.Add('cargo run --example entity_atlas')
$text.Add('.\scripts\validate_entity_atlas.ps1 -Engine ACAD2027 -TimeoutSeconds 40')
$text.Add('.\scripts\validate_entity_atlas.ps1 -Engine BCAD -TimeoutSeconds 40')
$text.Add('.\scripts\report_entity_atlas.ps1')
$text.Add('```')
$text.Add('')
$text.Add('Assets: checker.bmp is generated by the example; reference.pdf and reference.dwf are simple generated references; reference.dgn is an installed IntelliCAD template and has no authored test geometry; ltypeshp.shx is the locally installed shape font. Keep the assets directory beside the version directories. External resources are not included in the generic source generator.')
[IO.File]::WriteAllLines((Join-Path $rootPath 'report.md'),$text,[Text.Encoding]::UTF8)
$summary=[pscustomobject]@{drawings=$manifest.Count;cases=$manifest[0].cases.Count;attempts=$rows.Count;all_originals_unchanged=(@($rows|Where-Object {-not $_.source_unchanged}).Count -eq 0);engines=@(foreach($engine in $engines){$set=@($rows|Where-Object { $_.engine -eq $engine -and $_.status -ne 'STALE_RESULT' });[pscustomobject]@{engine=$engine;current_results=$set.Count;loaded=@($set|Where-Object loaded).Count;completed=@($set|Where-Object completed).Count;passed=@($set|Where-Object status -EQ 'PASS').Count}})}
$summary|ConvertTo-Json -Depth 6|Set-Content (Join-Path $rootPath 'summary.json') -Encoding utf8
$summary|ConvertTo-Json -Depth 6
