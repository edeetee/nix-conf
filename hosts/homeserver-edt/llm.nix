# Local LLM endpoint on homeserver-edt (llama.cpp server).
#
# The module and the reasoning are in modules/nixos/llama-cpp.nix and
# plans/local-qwen.md. This file only picks the model, the numbers, and whether
# the task-queue worker runs.
#
# Expect `localLlm` to fail until the GGUFs are on disk — that is deliberate:
# ExecStartPre names the missing file instead of loading a truncated one.
{ lib, pkgs, ... }:

let
  # Flip to true once there is a scratch clone and a few task files in
  # /var/lib/qwen-loop/queue. Off by default so a deploy cannot start a worker
  # nobody is watching.
  loopEnabled = false;
in
{
  localLlm = {
    enable = true;

    # D2 is still open: Vulkan wins decode, ROCm wins prefill on gfx1031, and
    # this loop is prefill-heavy. Start on the backend that needs no patch.
    backend = "vulkan";

    # IQ4_XS over Q4_K_M on purpose: 16.5 GiB instead of 20.6 GiB, which buys
    # roughly double the context and keeps real RAM free. A/B them
    # (plans/local-qwen.md §5.10) before deciding this is the keeper:
    #   model = "/mnt/hdd/models/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf";
    model = "/mnt/hdd/models/Qwen3.6-35B-A3B-UD-IQ4_XS.gguf";
    mmproj = "/mnt/hdd/models/mmproj-F16.gguf";

    port = 8080;
    # Stable id for clients; the pi configs use the same string.
    modelAlias = "qwen3.6-35b-a3b";
    # 16k is what a ~24 GB weights+KV pool affords at 4-bit; pi sessions using
    # this endpoint declare the same window.
    contextSize = 16384;
    # Roughly a third of the routed experts in RAM. Tune with llama-bench:
    # raise on a VRAM OOM, lower when prefill is too slow.
    cpuMoeLayers = lib.mkDefault 16;
  };

  # The host firewall is currently disabled, so this only documents intent (and
  # survives the day someone enables it).
  networking.firewall.allowedTCPPorts = [ 8080 ];

  # ── Autonomous task queue (plans/local-qwen.md §3.5) ────────────────────
  # One task = one pi invocation = one validated commit on a review branch.
  # The worker never pushes, and scripts/qwen-loop.sh refuses to target this
  # repo, so it cannot fight the deploy path or another agent's worktree.
  systemd.tmpfiles.rules = lib.mkIf loopEnabled [
    "d /var/lib/qwen-loop 0775 edeetee users - -"
    "d /var/lib/qwen-loop/queue 0775 edeetee users - -"
    "d /var/lib/qwen-loop/running 0775 edeetee users - -"
    "d /var/lib/qwen-loop/done 0775 edeetee users - -"
    "d /var/lib/qwen-loop/failed 0775 edeetee users - -"
  ];

  systemd.services.qwenLoop = lib.mkIf loopEnabled {
    description = "Local-model task queue worker (qwen-loop)";
    wantedBy = [ "multi-user.target" ];
    # Best-effort: if the endpoint is down the task fails its verify and the
    # worker keeps going, which is worse to debug than a plain dependency.
    after = [ "localLlm.service" ];
    wants = [ "localLlm.service" ];
    serviceConfig = {
      Type = "simple";
      User = "edeetee";
      Group = "users";
      WorkingDirectory = "/home/edeetee/dev/nix-conf";
      ExecStart = "${pkgs.bashNonInteractive}/bin/bash /home/edeetee/dev/nix-conf/scripts/qwen-loop.sh";
      Restart = "on-failure";
      RestartSec = 60;
      # No PATH here: it would collide with the NixOS-computed PATH and one of
      # them silently wins. scripts/qwen-loop.sh resolves pi itself.
      Environment = [
        "HOME=/home/edeetee"
        "QWEN_LOOP_DIR=/var/lib/qwen-loop"
      ];
    };
  };
}
