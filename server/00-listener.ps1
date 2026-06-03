function New-BridgeListener($prefix) {
  $l = New-Object System.Net.HttpListener
  $l.Prefixes.Add($prefix)
  $l.Start()
  return $l
}
