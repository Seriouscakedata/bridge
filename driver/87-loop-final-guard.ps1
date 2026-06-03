$script:DriverLoopFinalGuardBlock = {
  if (([int](Read-State).task_turn) -ge $maxTurns) {
    Add-Message -From system -Text "⏸ Достигнут лимит ходов по задаче ($maxTurns). Останавливаю задачу — уточни или дай новую." -Kind event | Out-Null
    try { Send-PushEvent -Kind need_you -Text "Достигнут лимит ходов ($maxTurns): $(Get-PushSnippet -Text $task)" } catch {}
    Update-State { param($s) Complete-TaskAgentDuration $s; Close-ReplayForStateTask -State $s -Status 'aborted'; $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; Clear-AuditorSuppressedHashes -State $s; Clear-FastLaneFlags $s; Clear-ChunkingState $s; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle'; $s | Add-Member -NotePropertyName task_restart_count -NotePropertyValue 0 -Force } | Out-Null
    continue
  }
  Start-Sleep -Seconds $loopDelay
}
