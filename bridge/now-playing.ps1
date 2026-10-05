# Prints TIDAL's Windows media session as JSON: {"title","playing","position_ms"}, or null.
# The bridge runs this before restarting TIDAL with remote control, to resume where it was.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
		$_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
	})[0]
function Await($op, [Type]$type) {
	$task = $asTask.MakeGenericMethod($type).Invoke($null, @($op))
	if (-not $task.Wait(3000)) { throw 'timeout' }
	$task.Result
}
[void][Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
$manager = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
$session = $manager.GetSessions() | Where-Object { $_.SourceAppUserModelId -match 'tidal' } | Select-Object -First 1
if ($null -eq $session) { 'null'; exit 0 }
$props = Await ($session.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
# A status read once can be stale (TIDAL reports Playing for a moment while it starts); only count
# it as playing when it still is a little later.
$playing = $session.GetPlaybackInfo().PlaybackStatus -eq 'Playing'
if ($playing) {
	Start-Sleep -Milliseconds 700
	$playing = $session.GetPlaybackInfo().PlaybackStatus -eq 'Playing'
}
$timeline = $session.GetTimelineProperties()
$position = ($timeline.Position - $timeline.StartTime).TotalMilliseconds
if ($playing) { $position += ([DateTimeOffset]::Now - $timeline.LastUpdatedTime).TotalMilliseconds }
@{ title = $props.Title; playing = $playing; position_ms = [long][Math]::Max(0, $position) } | ConvertTo-Json -Compress
