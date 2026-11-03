$scr = @"
_.LOGFILEON
_.FILEDIA 0
_.RECOVER
D:\GitHub\acadrust\tests\issue45_check\write_dxf_R2018_test.dxf
_.LOGFILEOFF
_.QUIT
"@
Set-Content -Path "$env:TEMP\opencode\issue45_test.scr" -Value $scr -Encoding Ascii
$p = Start-Process -FilePath "D:\Bricsys\BricsCAD\bricscad.exe" -ArgumentList '/nologo', '/b', "$env:TEMP\opencode\issue45_test.scr" -PassThru
$exited = $p.WaitForExit(150000)
if (-not $exited) { "TIMEOUT (modal likely)"; Get-Process -Name bricscad -ErrorAction SilentlyContinue | Stop-Process -Force } else { "EXITED" }
$log = Get-ChildItem "$env:LOCALAPPDATA\Bricsys\BricsCAD\V20x64\en_US" -Filter "write_dxf_R2018_test_*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($log) { $c = Get-Content $log.FullName -Raw; $total = [regex]::Match($c, "Total errors found during audit (\d+)").Groups[1].Value; "RECOVER audit errors: $total"; if ($total -ne "0") { $c | Select-String -Pattern "Name: |Value: |Validation" | ForEach-Object { $_.Line } | Select-Object -First 16 } } else { "no recover log" }

# Plain-OPEN hang test (modal = recovery prompt)
$scr2 = @"
_.FILEDIA 0
_.OPEN
D:\GitHub\acadrust\tests\issue45_check\write_dxf_R2018_test.dxf
_.QUIT
"@
Set-Content -Path "$env:TEMP\opencode\issue45_open.scr" -Value $scr2 -Encoding Ascii
$p2 = Start-Process -FilePath "D:\Bricsys\BricsCAD\bricscad.exe" -ArgumentList '/nologo', '/b', "$env:TEMP\opencode\issue45_open.scr" -PassThru
$exited2 = $p2.WaitForExit(75000)
if (-not $exited2) { "OPEN TEST: HUNG (recovery modal present)"; Get-Process -Name bricscad -ErrorAction SilentlyContinue | Stop-Process -Force } else { "OPEN TEST: EXITED CLEANLY (no recovery prompt)" }
