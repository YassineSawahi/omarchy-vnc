-- Keep the display lit while wayvnc is running.
--
-- Some monitors (HDMI ones especially) drop off the bus when powered off. When a VNC
-- client then wakes it, the connector bounces (unplugged, plugged in again)
-- and Hyprland 0.56 crashes removing the output wayvnc is capturing. So while
-- wayvnc runs, requests to power the display off are skipped: the lock
-- screen's blank 5 s after locking, and `omarchy brightness display off`.
-- The lock screen itself still shows. ~/.local/bin/vnc-wake powers the
-- display off once wayvnc stops, if the session is still locked (extras/vnc-wake).

-- Wrap the original only once, even when the config is reloaded.
vnc_original_dpms = vnc_original_dpms or hl.dsp.dpms

local function wayvnc_running()
  local pgrep = io.popen("pgrep -x wayvnc")
  if not pgrep then return false end
  local pids = pgrep:read("*a")
  pgrep:close()
  return pids ~= ""
end

hl.dsp.dpms = function(opts)
  if type(opts) == "table" and opts.action == "disable" and wayvnc_running() then
    return hl.dsp.exec_cmd("logger -t vnc-keep-lit 'Left the display on: wayvnc is running'")
  end
  return vnc_original_dpms(opts)
end
