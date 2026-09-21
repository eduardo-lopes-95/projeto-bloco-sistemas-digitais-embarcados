$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$sources = @(
    "$root/src/spi_image/gray_bowl_detector.v",
    "$root/src/spi_image/spi_slave_mode0.v",
    "$root/src/spi_image/spi_image_top.v"
)
New-Item -ItemType Directory -Force "$PSScriptRoot/build" | Out-Null
& iverilog -g2012 -Wall -s tb_spi_image -o "$PSScriptRoot/build/unit.vvp" "$PSScriptRoot/tb_spi_image.v" @sources
if ($LASTEXITCODE -ne 0) { throw 'RTL compilation failed' }
& vvp "$PSScriptRoot/build/unit.vvp"
if ($LASTEXITCODE -ne 0) { throw 'RTL tests failed' }
if (Test-Path "$PSScriptRoot/build/assembly_commands.hex") {
    & iverilog -g2012 -Wall -s tb_assembly_replay -o "$PSScriptRoot/build/replay.vvp" "$PSScriptRoot/tb_assembly_replay.v" @sources
    if ($LASTEXITCODE -ne 0) { throw 'Replay compilation failed' }
    & vvp "$PSScriptRoot/build/replay.vvp" "+FILE=$PSScriptRoot/build/assembly_commands.hex"
    if ($LASTEXITCODE -ne 0) { throw 'Assembly/RTL replay failed' }
} else {
    Write-Output 'Assembly replay skipped: first run tests/test_assembly_client.py in Linux/WSL.'
}
