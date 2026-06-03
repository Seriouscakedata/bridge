function Start-DriverMainLoop {
# ---------- main loop ----------
while ($true) {
 try {
  . $script:DriverLoopPreflightBlock
  . $script:DriverLoopIdleClaimBlock
  . $script:DriverLoopTurnSetupBlock
  . $script:DriverLoopAgentTurnBlock
  . $script:DriverLoopReplyMarkersBlock
  . $script:DriverLoopModeTransitionBlock
  . $script:DriverLoopCompletionBlock
  . $script:DriverLoopFinalGuardBlock
 } catch {
  try { Add-Message -From system -Text ("Ошибка драйвера: " + $_.Exception.Message + " -- продолжаю.") -Kind event | Out-Null } catch {}
  try { Update-State { param($s) $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null } | Out-Null } catch {}
  Start-Sleep -Seconds $loopDelay
 }
}
}
