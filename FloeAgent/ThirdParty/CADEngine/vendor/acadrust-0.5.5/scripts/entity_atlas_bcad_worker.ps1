param([string]$Drawing,[string]$Control,[string]$Directory)
$ErrorActionPreference='Stop'
$before=@(Get-Process bricscad -ErrorAction SilentlyContinue | ForEach-Object Id)
$application=$null
$document=$null
try {
    [IO.File]::WriteAllText((Join-Path $Directory 'stage.txt'),'STARTUP',[Text.Encoding]::ASCII)
    $application=New-Object -ComObject 'BricscadApp.AcadApplication.20.0'
    $owned=@(Get-Process bricscad | Where-Object { $_.Id -notin $before } | ForEach-Object Id)
    $owned | ConvertTo-Json | Set-Content (Join-Path $Directory 'engine-pids.json')
    $bootstrap=$application.Documents.Open($Control,[Type]::Missing)
    if($null -eq $bootstrap){throw 'BricsCAD control did not open'}
    $bootstrap.SetVariable('LOGFILEPATH',$Directory+'\')
    $bootstrap.SetVariable('LOGFILEMODE',[int16]1)
    [IO.File]::WriteAllText((Join-Path $Directory 'stage.txt'),'OPEN',[Text.Encoding]::ASCII)
    $document=$application.Documents.Open($Drawing,[Type]::Missing)
    if($null -eq $document){throw 'BricsCAD Documents.Open returned no document'}
    [IO.File]::WriteAllText((Join-Path $Directory 'loaded.txt'),($document.Name+'|'+$application.Version),[Text.Encoding]::UTF8)
    $document.SetVariable('LOGFILEPATH',$Directory+'\')
    $document.SetVariable('LOGFILEMODE',[int16]1)
    [IO.File]::WriteAllText((Join-Path $Directory 'stage.txt'),'ENUMERATE',[Text.Encoding]::ASCII)
    $document.SetVariable('AUDITCTL',[int16]1)
    $completion=(Join-Path $Directory 'complete.txt').Replace('\','/')
    $inventory=(Join-Path $Directory 'entities.txt').Replace('\','/')
    $command = @(
        ('(setq atlasOut (open "{0}" "w"))' -f $inventory),
        '(setq atlasSet (ssget "_X") atlasI 0)',
        '(defun atlasRow (e / d) (setq d (entget e)) (if d (write-line (strcat (cdr (assoc 8 d)) "|" (cdr (assoc 0 d)) "|" (cdr (assoc 5 d)) "|" (vl-princ-to-string (cdr (assoc 10 d)))) atlasOut) (write-line "_UNREADABLE|UNREADABLE||" atlasOut)))',
        '(if atlasSet (repeat (sslength atlasSet) (setq atlasErr (vl-catch-all-apply ''atlasRow (list (ssname atlasSet atlasI))) atlasI (1+ atlasI)) (if (vl-catch-all-error-p atlasErr) (write-line "_UNREADABLE|UNREADABLE||" atlasOut))))',
        '(close atlasOut)',
        '(command "_.AUDIT" "_N")',
        ('(setq atlasFinished (open "{0}" "w"))' -f $completion),
        '(write-line "COMPLETE" atlasFinished)',
        '(close atlasFinished)',
        ''
    ) -join "`n"
    $document.SendCommand($command)
    $until=(Get-Date).AddSeconds(25)
    while(-not (Test-Path (Join-Path $Directory 'complete.txt')) -and (Get-Date) -lt $until){Start-Sleep -Milliseconds 100}
} catch {
    [IO.File]::WriteAllText((Join-Path $Directory 'worker-error.log'),$_.Exception.ToString(),[Text.Encoding]::UTF8)
} finally {
    if($null -ne $document){try{$document.Close($false,[Type]::Missing)}catch{}}
    if($null -ne $application){try{$application.Quit()}catch{}}
}
