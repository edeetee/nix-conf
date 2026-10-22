# Local LLM endpoint: llama.cpp's `llama-server` as a system service.
#
# Design, measurements and the decisions behind these defaults live in
# plans/local-qwen.md. Short version: the GPU is the TV's GPU, RAM is tighter
# than VRAM, and the model is a 4-bit MoE whose experts are split between VRAM
# and DRAM.
#
# NixOS-only module: it uses systemd, tmpfiles and users. Never import it from
# modules/common.nix, which the Darwin configurations also consume.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.localLlm;

  # Both variants are in nixpkgs; neither needs an .override.
  package =
    {
      vulkan = pkgs.llama-cpp-vulkan;
      rocm = pkgs.llama-cpp-rocm;
    }
    .${cfg.backend};

  # Outside a login session there is no VK_ICD_FILENAMES in the environment, so
  # the Vulkan loader finds no driver and llama-server dies at start.
  backendEnv =
    {
      vulkan = {
        VK_ICD_FILENAMES = "${pkgs.mesa}/share/vulkan/icd.d/radeon_icd.${pkgs.stdenv.hostPlatform.parsed.cpu.name}.json";
        LD_LIBRARY_PATH = "/run/opengl-driver/lib";
      };
      rocm = {
        # gfx1031 (RX 6700 XT) is not a supported ROCm target: it only runs by
        # masquerading as gfx1030. Measure before choosing this backend — see the
        # ROCm/Vulkan split in plans/local-qwen.md §2 D2.
        HSA_OVERRIDE_GFX_VERSION = "10.3.0";
        LD_LIBRARY_PATH = "/run/opengl-driver/lib";
      };
    }
    .${cfg.backend};

  # `--fit` (llama.cpp's automatic layer/tensor/context fitting) is ON by
  # default in this version, so it is deliberately not passed here: the
  # remaining knobs below are the ones worth pinning.
  args = [
    "--model"
    cfg.model
    "--host"
    cfg.host
    "--port"
    (toString cfg.port)
    "--ctx-size"
    (toString cfg.contextSize)
    "--parallel"
    (toString cfg.parallel)
    "--cache-type-k"
    cfg.kvQuant
    "--cache-type-v"
    cfg.kvQuant
    "--flash-attn"
    "on"
    # Without --jinja the chat template is not applied and tool calls do not
    # work, which is the whole point of this endpoint.
    "--jinja"
  ]
  ++ lib.optionals (cfg.mmproj != null) [
    "--mmproj"
    cfg.mmproj
  ]
  ++ lib.optionals (cfg.sleepIdleSeconds != null) [
    "--sleep-idle-seconds"
    (toString cfg.sleepIdleSeconds)
  ]
  ++ lib.optionals (cfg.modelAlias != null) [
    "--alias"
    cfg.modelAlias
  ]
  ++ lib.optionals (cfg.cpuMoeLayers != null) [
    "--n-cpu-moe"
    (toString cfg.cpuMoeLayers)
  ]
  ++ cfg.extraArgs;

  # Fails the start rather than fighting for the GPU with something the user is
  # watching. Cheap and honest: the card has no useful preemption.
  guard = pkgs.writeShellScript "localLlm-guard" ''
    set -u

    if [ -e "${cfg.stateDir}/paused" ]; then
      echo "localLlm: paused (rm ${cfg.stateDir}/paused to allow starts)"
      exit 1
    fi
    ${lib.optionalString cfg.guardAgainstSteam ''
      if ${config.systemd.package}/bin/systemctl is-active --quiet steam-on-demand; then
        echo "localLlm: a Steam session is active, not taking the GPU"
        exit 1
      fi
    ''}
    if [ ! -r "${cfg.model}" ]; then
      echo "localLlm: model is not readable: ${cfg.model}" >&2
      echo "localLlm: fetch it with scripts/qwen-model.sh (plans/local-qwen.md §3.1)" >&2
      exit 1
    fi
  '';

  pause = pkgs.writeShellScriptBin "qwen-pause" ''
    touch "${cfg.stateDir}/paused"
    echo "localLlm paused — the service stays down until qwen-resume"
  '';

  resume = pkgs.writeShellScriptBin "qwen-resume" ''
    rm -f "${cfg.stateDir}/paused"
    echo "localLlm resumed — start it with: systemctl start localLlm"
  '';
in
{
  options.localLlm = {
    enable = lib.mkEnableOption "a local llama.cpp server (LAN OpenAI-compatible endpoint)";

    backend = lib.mkOption {
      type = lib.types.enum [
        "vulkan"
        "rocm"
      ];
      default = "vulkan";
      description = ''
        llama.cpp compute backend. On RDNA2, Vulkan wins decode and ROCm wins
        prefill; measure both before choosing (plans/local-qwen.md §2 D2).
      '';
    };

    model = lib.mkOption {
      type = lib.types.nonEmptyStr;
      example = "/mnt/hdd/models/Qwen3.6-35B-A3B-UD-IQ4_XS.gguf";
      description = ''
        Path to the GGUF. Deliberately a string, not `types.path`: a path would
        be copied into the Nix store, and a 20 GiB model in the store has to be
        re-downloaded on every garbage collection.
      '';
    };

    mmproj = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "Optional multimodal projector GGUF (enables image input).";
    };

    modelAlias = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = ''
        Passed as --alias: the name this endpoint reports, so a client's model id
        stays stable when the quant behind it changes.
      '';
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Bind address. The default is what makes this a LAN endpoint.";
    };

    sleepIdleSeconds = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = ''
        Passed as --sleep-idle-seconds: the server sleeps after this many idle
        seconds and wakes on the next request. This is the knob that makes the
        model "available but not running" — the first prompt after a sleep pays
        a full reload of the weights.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
    };

    contextSize = lib.mkOption {
      type = lib.types.ints.positive;
      default = 16384;
      description = ''
        Context window. On homeserver-edt this is limited by KV cache memory,
        not by the model: ~24 GB of usable weights+KV pool at 4-bit.
      '';
    };

    parallel = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Server slots. 1 on any host whose RAM is smaller than the model.";
    };

    kvQuant = lib.mkOption {
      type = lib.types.enum [
        "f16"
        "q8_0"
      ];
      default = "q8_0";
      description = ''
        KV cache type. q8_0 is close to free in quality; do not go below it —
        q4 KV specifically degrades long-context retrieval.
      '';
    };

    cpuMoeLayers = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = null;
      example = 16;
      description = ''
        Passed as --n-cpu-moe: keep the first N layers' routed experts in system
        RAM, which is how a model larger than VRAM runs at all. Raise it when
        the server OOMs on the GPU, lower it when prefill is too slow.
      '';
    };

    guardAgainstSteam = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Refuse to start while a Steam session is running.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "llama";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "llama";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/llama";
      description = ''
        Writable state: the `paused` flag, HOME and the shader/KV cache. Must be
        a dedicated directory — a tmpfiles rule chowns it (AGENTS.md rule 1).
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra llama-server arguments, appended last.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(lib.hasPrefix "/nix/store" cfg.model);
        message = "localLlm.model must not live in the Nix store (a 20 GiB GGUF would be re-fetched on every GC).";
      }
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      # /dev/dri and /dev/kfd
      extraGroups = [
        "render"
        "video"
      ];
      home = cfg.stateDir;
    };
    users.groups.${cfg.group} = { };

    # Group `users` so the login account can create/remove the pause flag
    # without sudo.
    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 2775 ${cfg.user} users - -"
    ];

    environment.systemPackages = [
      pause
      resume
    ];

    systemd.services.localLlm = {
      description = "Local LLM endpoint (llama.cpp server, ${cfg.backend})";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      # /mnt/hdd is a `nofail` mount: without this the started unit would read a
      # model path on the root filesystem that does not exist.
      unitConfig.RequiresMountsFor = [ (dirOf cfg.model) ];

      environment = {
        HOME = cfg.stateDir;
        XDG_CACHE_HOME = "${cfg.stateDir}/cache";
      }
      // backendEnv;

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        SupplementaryGroups = [
          "render"
          "video"
        ];
        ExecStartPre = guard;
        ExecStart = "${package}/bin/llama-server ${lib.escapeShellArgs args}";

        # A 20 GiB model load is slow; do not let systemd decide it hung.
        TimeoutStartSec = 600;
        Restart = "on-failure";
        RestartSec = 30;
        StartLimitBurst = 3;
        StartLimitIntervalSec = 900;
        LimitNOFILE = 65536;

        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadWritePaths = [ cfg.stateDir ];
      };
    };
  };
}
