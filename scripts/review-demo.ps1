# Simulates agents reviewing pending drafts in the draft_review queue via the review endpoint.
# ~60% approved as-is, ~30% approved with a small edit (agent adds a sign-off), ~10% rejected.
# human_queue drafts are left pending on purpose: that's the backlog a real team would see.
# Run from the project folder:  powershell -ExecutionPolicy Bypass -File scripts\review-demo.ps1

param(
  [string]$Url = "http://localhost:5678/webhook/review",
  [string[]]$Agents = @("gabriel", "nino", "luka")
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# newlines are escaped in SQL so each draft stays on one line
$rows = docker compose exec -T postgres psql -U postgres -d support -At -F "`t" -c "select id, replace(coalesce(draft_body, ''), E'\n', '\n') from drafts where review_status = 'pending' and routed_to = 'draft_review' order by id;"
if (-not $rows) { Write-Host "No pending drafts in draft_review."; exit 0 }

$counts = @{ approved = 0; edited = 0; rejected = 0 }

foreach ($row in $rows) {
  $parts  = $row -split "`t", 2
  $id     = [int]$parts[0]
  $draft  = $parts[1] -replace '\\n', "`n"
  $agent  = $Agents | Get-Random
  $roll   = Get-Random -Maximum 100

  if ($roll -lt 60) {
    $review = @{ draft_id = $id; action = "approve"; reviewed_by = $agent }
    $label = "approved as-is"; $counts.approved++
  } elseif ($roll -lt 90) {
    $review = @{ draft_id = $id; action = "approve"; reviewed_by = $agent; final_body = "$draft`n`nBest,`n$((Get-Culture).TextInfo.ToTitleCase($agent))" }
    $label = "approved with edit"; $counts.edited++
  } else {
    $review = @{ draft_id = $id; action = "reject"; reviewed_by = $agent }
    $label = "rejected"; $counts.rejected++
  }

  try {
    Invoke-RestMethod -Uri $Url -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes(($review | ConvertTo-Json))) -ContentType "application/json; charset=utf-8" | Out-Null
    Write-Host "draft $id -> $label by $agent"
  } catch {
    Write-Warning "draft $id failed: $($_.Exception.Message)"
  }
}

Write-Host "Done: $($counts.approved) as-is, $($counts.edited) edited, $($counts.rejected) rejected."
