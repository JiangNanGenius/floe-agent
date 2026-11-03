param(
    [string]$Root = 'target/entity-atlas',
    [string]$Output = 'src/docs/entity_status_matrix.md',
    [string[]]$Engines = @('ACAD2027','BCAD'),
    [string[]]$IsolatedRoots = @()
)
$ErrorActionPreference = 'Stop'
function SharedHash([string]$Path) {
    $stream = [IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { [Convert]::ToHexString($algorithm.ComputeHash($stream)) } finally { $algorithm.Dispose(); $stream.Dispose() }
}
$repo = Split-Path $PSScriptRoot -Parent
$rootPath = (Resolve-Path -LiteralPath $Root).Path
$manifest = @(Get-Content (Join-Path $rootPath 'manifest.json') -Raw | ConvertFrom-Json)
$versions = @('AC1012','AC1014','AC1015','AC1018','AC1021','AC1024','AC1027','AC1032')
$formats = @('dwg','dxf_ascii','dxf_binary')
if ($IsolatedRoots.Count -eq 0) {
    $parent = Split-Path $rootPath -Parent
    $control = Join-Path $parent 'entity-version-controls'
    if (Test-Path -LiteralPath (Join-Path $control 'manifest.json')) { $IsolatedRoots += $control }
    foreach ($corpus in Get-ChildItem -LiteralPath $parent -Directory -Filter 'entity-matrix-isolated*') {
        foreach ($caseRoot in Get-ChildItem -LiteralPath $corpus.FullName -Directory) {
            if (Test-Path -LiteralPath (Join-Path $caseRoot.FullName 'manifest.json')) {
                $IsolatedRoots += $caseRoot.FullName
            }
        }
    }
}
$cases = @($manifest | Where-Object version -EQ 'AC1032' | Select-Object -First 1 -ExpandProperty cases)
if ($cases.Count -eq 0) { throw 'The full AC1032 manifest is required for the entity catalog.' }
$results = @{}
$drawings = @{}
$evidence = [Collections.Generic.List[object]]::new()
function Load-Result($Drawing, [string]$Engine, [string]$SourceRoot) {
    $name = [IO.Path]::GetFileNameWithoutExtension($Drawing.file)
    $path = Join-Path $SourceRoot "validation/$Engine/$name/result.json"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $result = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $hash = $result.source_sha256
    if (-not $hash) {
        $copy = Join-Path $result.log_directory ([IO.Path]::GetFileName($result.file))
        if (Test-Path -LiteralPath $copy) { $hash = SharedHash $copy }
    }
    $current = (Test-Path -LiteralPath $Drawing.file) -and $hash -and
        $hash -eq (SharedHash $Drawing.file)
    $entry = [pscustomobject]@{result=$result; current=[bool]$current; path=$path; hash=$hash; drawing=$Drawing; checked=(Get-Item -LiteralPath $path).LastWriteTimeUtc}
    $evidence.Add([pscustomobject]@{engine=$Engine; version=$Drawing.version; format=$Drawing.format;
        file=$Drawing.file; result=$path; sha256=$hash; current=[bool]$current; status=$result.status})
    return $entry
}
foreach ($drawing in $manifest) {
    $drawings["$($drawing.version)|$($drawing.format)"] = $drawing
    foreach ($engine in $Engines) {
        $results["$engine|$($drawing.version)|$($drawing.format)"] = Load-Result $drawing $engine $rootPath
    }
}
$isolated = @{}
foreach ($isolatedRoot in $IsolatedRoots) {
    $path = (Resolve-Path -LiteralPath $isolatedRoot).Path
    foreach ($drawing in @(Get-Content (Join-Path $path 'manifest.json') -Raw | ConvertFrom-Json)) {
        foreach ($engine in $Engines) {
            $entry = Load-Result $drawing $engine $path
            foreach ($case in $drawing.cases) {
                $key = "$engine|$($drawing.version)|$($drawing.format)|$($case.name)"
                $previous = $isolated[$key]
                if ($entry -and (-not $previous -or
                    ($entry.current -and -not $previous.current) -or
                    ($entry.current -eq $previous.current -and $entry.checked -gt $previous.checked))) {
                    $isolated[$key] = $entry
                }
            }
        }
    }
}
function Expected-Types($Case) {
    switch -Regex ($Case.name) {
        '^DIM_(ARC|JOGGED)$' { return $Case.expected }
        '^DIM_' { return @('DIMENSION') }
        '^(POLYLINE|POLYLINE2D)$' { return @('POLYLINE','LWPOLYLINE') }
        '^(POLYLINE3D|POLYFACE|POLYGON_MESH)$' { return @('POLYLINE') }
        '^MINSERT$' { return @('INSERT','MINSERT') }
        '^SURFACE_GENERIC$' { return @('SURFACE') }
        '^SURFACE_' { return @($Case.name.Substring(8) + 'SURFACE') }
        '^SECTIONOBJECT$' { return @('SECTIONOBJECT') }
        '^RTEXT$' { return @('RTEXT') }
        '^POSITIONMARKER$' { return @('POSITIONMARKER') }
        '^(PDF|DWF|DGN)UNDERLAY$' { return @($Case.name, $Case.name.Replace('UNDERLAY','REFERENCE')) }
        '^ARCALIGNEDTEXT$' { return @('ARCALIGNEDTEXT') }
        default { return @($Case.expected) }
    }
}
function Status($Case, $Drawing, $Entry) {
    if ($null -eq $Drawing) { return 'UT' }
    $caseInDrawing = @($Drawing.cases | Where-Object name -EQ $Case.name) | Select-Object -First 1
    if (-not $caseInDrawing -or -not $caseInDrawing.included) { return 'NA' }
    if ($null -eq $Entry) { return 'UT' }
    if (-not $Entry.current) { return 'STALE' }
    $r = $Entry.result
    if ($r.status -eq 'ENGINE_STARTUP_FAILED') { return 'ENGINE' }
    if (-not $r.loaded) { return 'BLOCKED' }
    $records = @($r.records | Where-Object layer -EQ $caseInDrawing.layer)
    if ($records.type -match 'PROXY') { return 'PROXY' }
    if ($records.Count -eq 0) { return $(if($r.unreadable_records -gt 0){'UNREAD'}else{'MISSING'}) }
    $expected = @(Expected-Types $caseInDrawing)
    if (-not @($records | Where-Object { $_.type -in $expected }).Count) { return 'TYPE' }
    if (-not $r.completed -or $null -eq $r.audit_errors) { return 'INCOMPLETE' }
    if ($r.audit_errors -gt 0) { return 'AUDIT' }
    return 'OK'
}
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('# Entity Status By DWG/DXF Version')
$lines.Add('')
$lines.Add('Generated from console validation results. AutoCAD 2027 and BricsCAD V20.1; IntelliCAD excluded. A cell describes the tested fixture, not every possible configuration of that entity.')
$lines.Add('')
$lines.Add('`OK`: native type present, completed audit, zero errors. `PROXY`: retained only as a proxy. `TYPE`: unexpected native type. `MISSING`: case absent. `UNREAD`: absent with unreadable records. `AUDIT`: type present but drawing has audit errors, not necessarily attributable to this entity. `BLOCKED`: the entire drawing did not open, so this entity is untested in that drawing. `ENGINE`: engine startup failed before opening the drawing. `INCOMPLETE`: no completed audit. `UT`: not tested. `STALE`: source changed after validation. `NA`: excluded by the atlas version gate, not a claim about all possible down-conversions.')
$lines.Add('')
$lines.Add('`i:` prefixes an isolated-drawing result used when the combined drawing cannot establish the status. BricsCAD native underlay names PDFREFERENCE/DWFREFERENCE/DGNREFERENCE are accepted aliases. Native identity and audit do not verify appearance, exact topology or external assets. Structural records are covered indirectly through their parent entities; exclusions are listed below rather than silently treated as passing.')
$lines.Add('')
$lines.Add('## Version Availability')
$lines.Add('')
$lines.Add('This is the minimum version selected for the fixture, not a guarantee that every API field is native in that version. See the engine matrices for actual results.')
$lines.Add('')
$lines.Add('| Case | First Atlas Version | '+($versions -join ' | ')+' |')
$lines.Add('|---|---|'+((@('---') * $versions.Count) -join '|')+'|')
foreach ($case in $cases) {
    $available = @($versions | ForEach-Object { if($_ -ge $case.minimum_version){'YES'}else{'NA'} })
    $lines.Add('| '+$case.name+' | '+$case.minimum_version+' | '+($available -join ' | ')+' |')
}
$cells = [Collections.Generic.List[object]]::new()
foreach ($engine in $Engines) {
    foreach ($format in $formats) {
        $lines.Add(''); $lines.Add("## $engine / $format"); $lines.Add('')
        $lines.Add('| Entity | '+($versions -join ' | ')+' |')
        $lines.Add('|---|'+((@('---') * $versions.Count) -join '|')+'|')
        foreach ($case in $cases) {
            $values = @(foreach ($version in $versions) {
                $drawing = $drawings["$version|$format"]
                $entry = $results["$engine|$version|$format"]
                $status = Status $case $drawing $entry
                $scope = 'combined'
                if ($status -in @('BLOCKED','UT','STALE','INCOMPLETE','ENGINE')) {
                    $single = $isolated["$engine|$version|$format|$($case.name)"]
                    if ($single -and $single.current) {
                        $entry = $single
                        $status = 'i:' + (Status $case $single.drawing $single)
                        $scope = 'isolated'
                    }
                }
                $cells.Add([pscustomobject]@{entity=$case.name; engine=$engine; version=$version; format=$format;
                    status=$status; scope=$scope; result_path=$(if($entry){[IO.Path]::GetRelativePath($repo,$entry.path).Replace('\','/')}else{$null})})
                $status
            })
            $lines.Add('| '+$case.name+' | '+($values -join ' | ')+' |')
        }
    }
}
$summary = [Collections.Generic.List[string]]::new()
$summary.Add('## DWG Progress')
$summary.Add('')
$summary.Add('Counts include isolated results where the combined atlas cannot open. Not verified includes blocked opens, stale evidence, engine failures and untested cases. Issue cells include proxies and non-native or incomplete results; they are not passes.')
$summary.Add('')
$summary.Add('| Engine | Version | Native, Audit-Clean | Proxy | Other Issues | Not Verified | Excluded |')
$summary.Add('|---|---|---:|---:|---:|---:|---:|')
foreach ($engine in $Engines) {
    foreach ($version in $versions) {
        $states = @($cells | Where-Object { $_.engine -eq $engine -and $_.format -eq 'dwg' -and $_.version -eq $version } | ForEach-Object { $_.status -replace '^i:', '' })
        $ok = @($states | Where-Object { $_ -eq 'OK' }).Count
        $proxy = @($states | Where-Object { $_ -eq 'PROXY' }).Count
        $excluded = @($states | Where-Object { $_ -eq 'NA' }).Count
        $unverified = @($states | Where-Object { $_ -in @('BLOCKED','STALE','UT','ENGINE') }).Count
        $issues = $states.Count - $ok - $proxy - $excluded - $unverified
        $summary.Add("| $engine | $version | $ok | $proxy | $issues | $unverified | $excluded |")
    }
}
$summary.Add('')
$lines.InsertRange($lines.IndexOf('## Version Availability'), $summary)
$lines.Add(''); $lines.Add('## Structural And Unsynthesized Entities'); $lines.Add('')
$lines.Add('| Entity/API Family | '+($versions -join ' | ')+' | Coverage/Requirement |')
$lines.Add('|---|'+((@('---') * 9) -join '|')+'|')
foreach ($row in @(
    @('BLOCK / ENDBLK','INDIRECT','INSERT, MINSERT, ATTRIB and TABLE ownership; not separate graphical cases'),
    @('VERTEX / SEQEND','INDIRECT','Polyline2D/3D, polygon/polyface meshes and INSERT attributes'),
    @('OLE2FRAME / OLEFRAME','UT','Embedded OLE application payload required'),
    @('SECTIONLINE / DRAWINGVIEW','UT','SectionSymbol/ViewBorder require a model-documentation object graph'),
    @('ACDBPOINTCLOUD / ACDBPOINTCLOUDEX','UT','External indexed point-cloud data required'),
    @('COORDINATION_MODEL','UT','External coordination-model data required'),
    @('LAYOUTPRINTCONFIG / Format','UT','Structured extended entity, no independent fixture'),
    @('ACAD_PROXY_ENTITY / RegisteredClass / Unknown','UT','Caller-supplied class/payload; cannot certify arbitrary third-party records'),
    @('REPEAT / ENDREP / LOAD / JUMP','NA','Legacy pre-R13 records, outside supported output versions')
)) { $lines.Add('| '+$row[0]+' | '+((@($row[1]) * 8) -join ' | ')+' | '+$row[2]+' |') }
$dynamicSource = Get-Content (Join-Path $repo 'src/objects/dynamic_block.rs') -Raw
$dynamicMethod = [regex]::Match($dynamicSource,'(?s)pub fn entity_dxf_name.*?pub fn entity_cpp_name').Value
foreach ($name in @([regex]::Matches($dynamicMethod,'Some\("([A-Z0-9_]+)"\)') | ForEach-Object {$_.Groups[1].Value} | Sort-Object -Unique)) {
    $lines.Add("| $name | "+((@('UT') * 8) -join ' | ')+' | Dynamic-block parameter/grip graph required |')
}
$lines.Add(''); $lines.Add('## Public Entity API Checklist'); $lines.Add('')
$coverage = @{
    AttributeDefinition='ATTDEF'; AttributeEntity='ATTRIB'; Block='BLOCK (indirect)'; BlockEnd='ENDBLK (indirect)';
    Dimension='DIM_* (9 cases)'; Hatch='HATCH_SOLID / HATCH_PATTERN'; Insert='INSERT / MINSERT / ATTRIB';
    PolyfaceMesh='POLYFACE'; PolygonMesh='POLYGON_MESH'; RasterImage='IMAGE'; Solid3D='3DSOLID_* (7 cases)';
    Surface='SURFACE_* (7 cases)'; Underlay='PDFUNDERLAY / DWFUNDERLAY / DGNUNDERLAY';
    Light='LIGHT_* (3 cases)'; Seqend='SEQEND (indirect)'; Ole2Frame='UT'; SectionSymbol='UT'; ViewBorder='UT';
    Unknown='UT'; Extended='CAMERA / SECTIONOBJECT / RTEXT / POSITIONMARKER / ARCALIGNEDTEXT plus the unsynthesized families above'
}
$source = Get-Content (Join-Path $repo 'src/entities/mod.rs') -Raw
$entityEnum = [regex]::Match($source,'(?s)pub enum EntityType \{(.*?)\n\}').Groups[1].Value
foreach ($variant in @([regex]::Matches($entityEnum,'(?m)^    (\w+)\(') | ForEach-Object {$_.Groups[1].Value})) {
    $mapped = $coverage[$variant]
    if (-not $mapped) {
        $mapped = $variant.ToUpperInvariant()
        if ($mapped -eq 'FACE3D') { $mapped = '3DFACE' }
        if ($mapped -notin $cases.name) { throw "Unmapped public entity variant: $variant" }
    }
    $lines.Add("- [x] ${variant}: $mapped")
}
$lines.Add(''); $lines.Add('Checkboxes mean cataloged, not compatible. UT/NA and proxy/failure cells remain unresolved.'); $lines.Add('')
$lines.Add('Rebuild: `scripts/entity_status_matrix.ps1`. The standard entity-version-controls and entity-matrix-isolated* corpora are discovered automatically; pass `-IsolatedRoots` to select explicit corpora. Regenerate and validate isolated drawings when changing the writer. Machine-readable cell data and evidence hashes are in `entity_status_matrix.json` beside this document.')
$outputPath = [IO.Path]::GetFullPath($Output)
[IO.File]::WriteAllLines($outputPath,$lines,[Text.Encoding]::UTF8)
foreach ($item in $evidence) {
    $item.file = [IO.Path]::GetRelativePath($repo,$item.file).Replace('\','/')
    $item.result = [IO.Path]::GetRelativePath($repo,$item.result).Replace('\','/')
}
[IO.File]::WriteAllText([IO.Path]::ChangeExtension($outputPath,'.json'),
    ([pscustomobject]@{versions=$versions; cases=@($cases | Select-Object id,name,minimum_version,expected); cells=$cells; evidence=$evidence} | ConvertTo-Json -Depth 20 -Compress),[Text.Encoding]::UTF8)
"Wrote $($cases.Count) entity cases, $($cells.Count) engine/format/version cells to $outputPath"
