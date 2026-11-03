param(
    [string]$Root = 'target/entity-atlas',
    [ValidateSet('ACAD2027','BCAD','ICAD')][string]$Engine = 'ACAD2027',
    [string]$Filter = '*',
    [int]$TimeoutSeconds = 25,
    [switch]$Resume,
    [switch]$RetryLoaded,
    [switch]$RefreshLoaded
)
$ErrorActionPreference = 'Stop'
$rootPath = (Resolve-Path -LiteralPath $Root).Path
$executables = @{
    ACAD2027 = 'C:\Program Files\Autodesk\AutoCAD 2027\accoreconsole.exe'
    BCAD = 'E:\Bricsys\BricsCAD\bricscad.exe'
    ICAD = 'C:\Program Files\CMS\CMS IntelliCAD 15.0 Premium Edition Plus\CmsIcad.exe'
}
$executable = $executables[$Engine]
if (-not (Test-Path -LiteralPath $executable)) { throw "Missing engine: $executable" }
$manifest = Get-Content -LiteralPath (Join-Path $rootPath 'manifest.json') -Raw | ConvertFrom-Json
$resultsRoot = Join-Path $rootPath "validation/$Engine"
New-Item -ItemType Directory -Force -Path $resultsRoot | Out-Null
$results = [Collections.Generic.List[object]]::new()
function SharedHash([string]$Path) {
    $stream = [IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { [Convert]::ToHexString($algorithm.ComputeHash($stream)) } finally { $algorithm.Dispose(); $stream.Dispose() }
}
function LispPath([string]$Path) { $Path.Replace('\','/').Replace('"','\"') }
function ReadLog([string]$Path) {
    $stream = [IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { $memory=[IO.MemoryStream]::new(); $stream.CopyTo($memory); $bytes=$memory.ToArray(); $memory.Dispose() } finally { $stream.Dispose() }
    if ($bytes.Length -gt 3 -and $bytes[1] -eq 0) { return [Text.Encoding]::Unicode.GetString($bytes) }
    [Text.Encoding]::UTF8.GetString($bytes)
}

if ($Engine -eq 'BCAD') {
    if (Get-Process bricscad -ErrorAction SilentlyContinue) { throw 'Close existing BricsCAD instances before running the isolated console validator.' }
}
foreach ($drawing in $manifest) {
    $name = [IO.Path]::GetFileNameWithoutExtension($drawing.file)
    if ($name -notlike $Filter) { continue }
    $directory = Join-Path $resultsRoot $name
    $previous = Join-Path $directory 'result.json'
    if($RefreshLoaded -and (Test-Path -LiteralPath $previous)){
        $oldResult=Get-Content -LiteralPath $previous -Raw|ConvertFrom-Json
        if(-not $oldResult.loaded){$results.Add($oldResult);continue}
    }
    if($RetryLoaded -and (Test-Path -LiteralPath $previous)){
        $oldResult=Get-Content -LiteralPath $previous -Raw|ConvertFrom-Json
        if(-not $oldResult.loaded -or $oldResult.completed){$results.Add($oldResult);continue}
    }
    if ($Resume -and (Test-Path -LiteralPath $previous)) {
        $oldResult = Get-Content -LiteralPath $previous -Raw | ConvertFrom-Json
        if ($oldResult.source_sha256 -eq (SharedHash $drawing.file) -and
            $oldResult.status -ne 'ENGINE_STARTUP_FAILED' -and -not $oldResult.timed_out) {
            $results.Add($oldResult)
            continue
        }
    }
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $copy = Join-Path $directory ([IO.Path]::GetFileName($drawing.file))
    Copy-Item -LiteralPath $drawing.file -Destination $copy -Force
    # SHAPE test records reference AutoCAD's standard shape font by name.
    # Keep the validation self-contained because accoreconsole does not add
    # its Fonts directory to the per-process search path.
    $shapeFont = 'C:\Program Files\Autodesk\AutoCAD 2027\Fonts\ltypeshp.shx'
    if (Test-Path -LiteralPath $shapeFont) {
        Copy-Item -LiteralPath $shapeFont -Destination (Join-Path $directory 'ltypeshp.shx') -Force
    }
    $sourceHash = SharedHash $drawing.file
    $script = Join-Path $directory 'audit.scr'
    $entities = Join-Path $directory 'entities.txt'
    $loaded = Join-Path $directory 'loaded.txt'
    $complete = Join-Path $directory 'complete.txt'
    $stdout = Join-Path $directory 'stdout.log'
    $stderr = Join-Path $directory 'stderr.log'
    foreach ($old in @($entities,$loaded,$complete,(Join-Path $directory 'engine-pids.json'),(Join-Path $directory 'stage.txt'))) { if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old } }
    $lines = @(
        '(setq atlasOldLogPath (getvar "LOGFILEPATH") atlasOldLogMode (getvar "LOGFILEMODE"))',
        ('(setvar "LOGFILEPATH" "{0}")' -f (LispPath ($directory + '/'))),
        '(setvar "LOGFILEMODE" 1)',
        ('(setq atlasOut (open "{0}" "w"))' -f (LispPath $loaded)),
        '(write-line (strcat (getvar "DWGNAME") "|" (getvar "ACADVER")) atlasOut)',
        '(close atlasOut)',
        '_.AUDIT',
        '_N',
        ('(setq atlasOut (open "{0}" "w"))' -f (LispPath $entities)),
        '(setq atlasSet (ssget "_X") atlasI 0)',
        '(defun atlasRow (e / d) (setq d (entget e)) (if d (write-line (strcat (cdr (assoc 8 d)) "|" (cdr (assoc 0 d)) "|" (cdr (assoc 5 d)) "|" (vl-princ-to-string (cdr (assoc 10 d)))) atlasOut) (write-line "_UNREADABLE|UNREADABLE||" atlasOut)))',
        '(if atlasSet (repeat (sslength atlasSet) (setq atlasErr (vl-catch-all-apply ''atlasRow (list (ssname atlasSet atlasI))) atlasI (1+ atlasI)) (if (vl-catch-all-error-p atlasErr) (write-line "_UNREADABLE|UNREADABLE||" atlasOut))))',
        '(close atlasOut)',
        '(command "_.ZOOM" "_W" (list -20 -1340) (list 1080 150))',
        ('(setq atlasOut (open "{0}" "w"))' -f (LispPath $complete)),
        '(write-line "COMPLETE" atlasOut)',
        '(close atlasOut)',
        '(setvar "LOGFILEMODE" atlasOldLogMode)',
        '(setvar "LOGFILEPATH" atlasOldLogPath)',
        '_.QUIT',
        $(if ($Engine -eq 'ACAD2027') { '_Y' } else { '_N' })
    )
    [IO.File]::WriteAllLines($script,$lines,[Text.Encoding]::ASCII)
    $processExecutable=$executable
    $arguments = if ($Engine -eq 'ACAD2027') {
        '/i "{0}" /s "{1}" /readonly' -f $copy,$script
    } elseif ($Engine -eq 'BCAD') {
        $processExecutable=(Get-Process -Id $PID).Path
        '-NoProfile -File "{0}" -Drawing "{1}" -Control "{2}" -Directory "{3}"' -f (Join-Path $PSScriptRoot 'entity_atlas_bcad_worker.ps1'),$copy,(Join-Path $rootPath 'validation-control.dwg'),$directory
    } else {
        '"{0}" /nologo /b "{1}"' -f $copy,$script
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $runStarted = Get-Date
    $timedOut=$false
    $process = Start-Process -FilePath $processExecutable -ArgumentList $arguments -WorkingDirectory $directory -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $completed = $false
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-Path -LiteralPath $complete) { $completed = $true; break }
        if ($process.HasExited) { break }
        Start-Sleep -Milliseconds 200
    }
    if (-not $process.HasExited -and -not $process.WaitForExit(1500)) {
        $timedOut = -not (Test-Path -LiteralPath $complete)
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $process.WaitForExit()
    }
    if($Engine -eq 'BCAD'){
        # COM can start its server before returning an application reference.
        # A startup timeout therefore may precede the worker's PID file.
        $startupServers=@(Get-CimInstance Win32_Process -Filter "name='bricscad.exe'" | Where-Object {
            $_.CreationDate -ge $runStarted -and $_.ExecutablePath -eq $executable -and
            $_.CommandLine -match '/Automation.*-Embedding'
        } | ForEach-Object ProcessId)
        $pidFile=Join-Path $directory 'engine-pids.json'
        if(Test-Path -LiteralPath $pidFile){
            foreach($enginePid in @(Get-Content $pidFile -Raw | ConvertFrom-Json)){
                $owned=Get-Process -Id $enginePid -ErrorAction SilentlyContinue
                if($owned -and $owned.ProcessName -eq 'bricscad'){Stop-Process -Id $enginePid -Force; $owned.WaitForExit()}
            }
        }
        foreach($enginePid in $startupServers){
            $owned=Get-Process -Id $enginePid -ErrorAction SilentlyContinue
            if($owned -and $owned.StartTime -ge $runStarted){Stop-Process -Id $enginePid -Force; $owned.WaitForExit()}
        }
    }
    $completed = Test-Path -LiteralPath $complete
    $wasLoaded = $false
    if(Test-Path -LiteralPath $loaded) {
        $loadedName = (Get-Content -LiteralPath $loaded -First 1).Split('|')[0]
        $wasLoaded = [IO.Path]::GetFileNameWithoutExtension($loadedName) -eq $name
    }
    $logText = (Get-ChildItem $directory -File | Where-Object {
        $_.Extension -in '.log','.adt' -and $_.LastWriteTime -ge $runStarted
    } | ForEach-Object { ReadLog $_.FullName }) -join "`n"
    $auditMatches = [regex]::Matches($logText,'(?im)Total errors found(?: during audit)?\s+(\d+)[,\s]+fixed\s+(\d+)|Errors\s*:\s*(\d+)')
    $auditErrors = $null
    if ($auditMatches.Count -gt 0) {
        $auditErrors = 0
        foreach ($match in $auditMatches) {
            $count = if($match.Groups[1].Success){[int]$match.Groups[1].Value}else{[int]$match.Groups[3].Value}
            $auditErrors = [Math]::Max($auditErrors,$count)
        }
    }
    $records = @()
    if (Test-Path -LiteralPath $entities) {
        $records = @(Get-Content $entities | ForEach-Object { $fields=$_.Split('|',4); if($fields.Length -eq 4){[pscustomobject]@{layer=$fields[0];type=$fields[1];handle=$fields[2];position=$fields[3]}} })
    }
    $included = @($drawing.cases | Where-Object { $_.included -and $_.expected.Count -gt 0 })
    $caseResults = @($included | ForEach-Object {
        $case=$_; $actual=@($records | Where-Object layer -EQ $case.layer)
        [pscustomobject]@{id=$case.id;name=$case.name;layer=$case.layer;present=($actual.Count -gt 0);actual_types=@($actual.type);positions=@($actual.position);expected=$case.expected}
    })
    $missing = @($caseResults | Where-Object { -not $_.present } | ForEach-Object name)
    $unreadable=@($records | Where-Object type -EQ 'UNREADABLE').Count
    $proxyRecords=@($records | Where-Object { $_.type -match 'PROXY' -and $_.layer -like 'E*' }).Count
    $status = if(-not $wasLoaded){'OPEN_FAILED_OR_BLOCKED'}elseif(-not $completed){'AUDIT_OR_SCRIPT_FAILED'}elseif($null -eq $auditErrors){'AUDIT_SUMMARY_UNAVAILABLE'}elseif($auditErrors -gt 0){'AUDIT_ERRORS'}elseif($unreadable -gt 0){'UNREADABLE_ENTITIES'}elseif($proxyRecords -gt 0){'PROXY_ENTITIES'}elseif($missing.Count -gt 0){'ENTITY_LOSS'}else{'PASS'}
    $diagnostics = @($logText -split "`r?`n" | Where-Object { $_ -match 'ErrorStatus|improperly|corrupt|recover|Invalid|invalid|modeling failure|Modeling operation error|64 bit long|not found|unable|Unable|Error [0-9]|discarded|unknown command' } | Select-Object -Unique)
    $stage=if(Test-Path (Join-Path $directory 'stage.txt')){Get-Content (Join-Path $directory 'stage.txt') -Raw}else{''}
    if($Engine -eq 'BCAD' -and $stage -eq 'STARTUP' -and -not $wasLoaded){$status='ENGINE_STARTUP_FAILED'}
    $row=[pscustomobject]@{engine=$Engine;version=$drawing.version;format=$drawing.format;file=$drawing.file;status=$status;loaded=$wasLoaded;completed=$completed;unreadable_records=$unreadable;timed_out=$timedOut;stage=$stage;audit_errors=$auditErrors;expected_cases=$included.Count;present_cases=($included.Count-$missing.Count);missing=$missing;records=$records;cases=$caseResults;diagnostics=$diagnostics;seconds=[Math]::Round($timer.Elapsed.TotalSeconds,2);source_unchanged=((SharedHash $drawing.file) -eq $sourceHash);log_directory=$directory}
    $row | Add-Member -NotePropertyName source_sha256 -NotePropertyValue $sourceHash
    $row | Add-Member -NotePropertyName proxy_records -NotePropertyValue $proxyRecords
    $results.Add($row)
    $row | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $directory 'result.json') -Encoding utf8
    $results | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $resultsRoot 'results.json') -Encoding utf8
    '{0} {1} {2}: {3}, cases={4}/{5}, audit={6}, {7}s' -f $Engine,$drawing.version,$drawing.format,$status,$row.present_cases,$row.expected_cases,$auditErrors,$row.seconds
}
