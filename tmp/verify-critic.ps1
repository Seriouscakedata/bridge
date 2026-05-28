. 'C:\Users\rafie\OneDrive\Documents\bridge\lib\common.ps1'
$s1 = Get-EffectiveScope -Slug 'main'
$s2 = Get-EffectiveScope -Slug 'travel'
$arch = Get-ArchitectScope
$ok1 = [bool](Get-Command Invoke-WithChannelEnv -ErrorAction SilentlyContinue)
$ok2 = [bool](Get-Command Get-EffectiveScope -ErrorAction SilentlyContinue)
$effFr = (Get-EffectiveScope).features_registry
@{
  invoke_with_env_exists = $ok1
  effective_scope_exists = $ok2
  main_is_bridge = $s1.is_bridge
  travel_is_bridge = $s2.is_bridge
  travel_features = $s2.features_registry
  travel_memory = $s2.memory_store
  architect_slug = $arch.slug
  architect_features_eq_effective = ($arch.features_registry -eq $effFr)
} | ConvertTo-Json -Compress -Depth 4
