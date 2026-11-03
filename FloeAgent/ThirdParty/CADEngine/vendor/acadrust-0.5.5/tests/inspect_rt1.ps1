foreach ($f in @("tests\issue64\byblock_repro_input.dxf", "tests\issue64\byblock_repro_output.dxf")) {
    "=== $f"
    $lines = [System.IO.File]::ReadAllLines($f)
    for ($i = 0; $i -lt $lines.Length - 3; $i++) {
        if ($lines[$i] -eq "  0" -and $lines[$i + 1] -eq "TABLE") {
            $name = $lines[$i + 3]
            $h = "?"
            for ($j = $i + 4; $j -lt [Math]::Min($i + 14, $lines.Length - 1); $j += 2) {
                if ($lines[$j] -eq "  5") { $h = $lines[$j + 1].Trim(); break }
            }
            "  TABLE $name handle=$h"
        }
    }
}
