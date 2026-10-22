# Local LLM endpoint on homeserver-edt (llama.cpp server).
#
# The module and the reasoning are in modules/nixos/llama-cpp.nix and
# plans/local-qwen.md. This file only picks the model and the numbers.
#
# Expect it to fail until the GGUFs are on disk — that is deliberate: the unit's
# ExecStartPre says which file is missing, rather than loading a truncated one.
{ lib, ... }:

{
  localLlm = {
    enable = true;

    # D2 is still open: Vulkan wins decode, ROCm wins prefill on gfx1031, and
    # this loop is prefill-heavy. Start on the backend that needs no patch.
    backend = "vulkan";

    # IQ4_XS over Q4_K_M on purpose: 16.5 GiB instead of 20.6 GiB, which buys
    # ~2x the context and keeps real RAM free. A/B them (plans/local-qwen.md
    # §5.10) before deciding this is the keeper:
    #   model = "/mnt/hdd/models/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf";
    model = "/mnt/hdd/models/Qwen3.6-35B-A3B-UD-IQ4_XS.gguf";
    mmproj = "/mnt/hdd/models/mmproj-F16.gguf";

    port = 8080;
    # Stable id for clients; darwin/pi-agent/models.json uses the same string.
    modelAlias = "qwen3.6-35b-a3b";
    # 16k is what ~24 GB of weights+KV pool affords at 4-bit; the pi sessions
    # that use this endpoint are configured with the same window.
    contextSize = 16384;
    # Roughly a third of the routed experts in RAM. Tune with llama-bench:
    # raise on a VRAM OOM, lower when prefill is too slow.
    cpuMoeLayers = lib.mkDefault 16;
  };

  # The host firewall is currently disabled, so this only documents intent (and
  # survives the day someone enables it).
  networking.firewall.allowedTCPPorts = [ 8080 ];
}
