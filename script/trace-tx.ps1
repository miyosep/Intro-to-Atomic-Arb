# Trace original MEV tx to analyze call structure
# Requires: MAINNET_RPC_URL env var (Alchemy/Infura with archive support)
# Output: trace-output.txt

$TX_HASH = "0x9edea0b66aece76f0bc7e185f9ce5cac81ce41bdd1ec4d3cf1907274bc8aa730"
$RPC = $env:MAINNET_RPC_URL
if (-not $RPC) {
    Write-Host "ERROR: Set MAINNET_RPC_URL first (e.g. Alchemy archive RPC)" -ForegroundColor Red
    exit 1
}

Write-Host "Tracing tx $TX_HASH ..." -ForegroundColor Cyan
Write-Host "RPC: $RPC" -ForegroundColor Gray

$outFile = "trace-output.txt"
cast run $TX_HASH --rpc-url $RPC -vvvv 2>&1 | Tee-Object -FilePath $outFile

Write-Host "`nTrace saved to $outFile" -ForegroundColor Green
