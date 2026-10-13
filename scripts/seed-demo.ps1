# Sends the labelled eval tickets through the LIVE triage flow as demo traffic.
# Run from the project folder:  powershell -ExecutionPolicy Bypass -File scripts\seed-demo.ps1
# Ticket triage must be published (production URL /webhook/ticket).
# Groq free tier allows ~8K tokens/min; one ticket uses ~2K, so we wait between sends.

param(
  [int]$DelaySeconds = 20,
  [string]$Url = "http://localhost:5678/webhook/ticket"
)

$accounts = @(
  @{ name = "Acme";      email = "anna@acme.com" },
  @{ name = "Globex";    email = "mark@globex.com" },
  @{ name = "Initech";   email = "peter@initech.io" },
  @{ name = "Umbrella";  email = "alice@umbrella.co" },
  @{ name = "Hooli";     email = "gavin@hooli.xyz" },
  @{ name = "Stark Ads"; email = "pepper@starkads.com" }
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# pull subject + body for every eval case, tab separated
$rows = docker compose exec -T postgres psql -U postgres -d support -At -F "`t" -c "select subject, body from eval_cases order by id;"
if (-not $rows) { Write-Error "Could not read eval_cases. Is the stack running?"; exit 1 }

$i = 0
foreach ($row in $rows) {
  $i++
  $parts = $row -split "`t", 2
  $acct = $accounts | Get-Random
  $body = @{
    subject        = $parts[0]
    body           = $parts[1]
    customer_email = $acct.email
    account_name   = $acct.name
  } | ConvertTo-Json

  try {
    Invoke-RestMethod -Uri $Url -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -ContentType "application/json; charset=utf-8" | Out-Null
    Write-Host "[$i/$($rows.Count)] sent: $($parts[0])"
  } catch {
    Write-Warning "[$i/$($rows.Count)] failed: $($parts[0]) -> $($_.Exception.Message)"
  }
  if ($i -lt $rows.Count) { Start-Sleep -Seconds $DelaySeconds }
}

Write-Host "Done. Wait ~30 seconds for the last ticket, then run scripts\review-demo.ps1"
