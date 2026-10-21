# Plasma Bigscreen, overlaid into a Plasma 6.6 system.
#
# Why this exists: `kdePackages.plasma-bigscreen` does not exist in the pinned
# nixpkgs (Plasma 6.6.4 — nor in nixos-25.11 / nixos-26.05; it first appears at
# Plasma 6.7). The alternative was a full nixpkgs bump. This is the middle path
# from plans/plasma-bigscreen.md §9.1: build upstream's 6.7.5 sources with
# **this** nixpkgs' KDE scope, so the shell is linked against the Qt/KF6/plasma
# it will actually run on.
#
# The recipe is transcribed from nixpkgs' pkgs/kde/plasma/plasma-bigscreen
# rather than imported from a newer nixpkgs, for two reasons: that file does not
# accept `version`/`src` overrides, and mkKdeDerivation's defaults for them come
# from `self.sources.<pname>` — a table of *this* nixpkgs' plasma release, which
# has no entry for a package that is not in the tree. Passing both here keeps
# the whole thing self-contained (no second nixpkgs input).
#
# Deliberate choices:
#
#   * version **v6.7.5**, not the newest: the runtime is Plasma 6.6, so the
#     closest release is the smallest QML-API leap. There is no 6.6-stable
#     bigscreen — the earliest tags (v6.6.90/.91) are the 6.7 betas.
#   * the non-KDE build inputs (`libcec`, `sdl3`) are passed from the overlayed
#     `prev` explicitly: they are not members of the KDE scope, so
#     `kdePackages.callPackage` would not resolve them.
#
# This is a pushed-forward, unsupported combination: if 6.7's QML imports
# something 6.6 does not provide, the TV session comes up blank. The desktop
# session is unaffected and `tv-session plasma` from a TTY still works. If that
# happens, delete this module — nothing else depends on it.
{ nixpkgs-bigscreen, ... }:
let
  # mkKdeDerivation from the newer tree, bound to *this* nixpkgs' KDE scope.
  # The pinned one would be ideal, but it resolves descriptions, licences and
  # dependency lists out of `pkgs/kde/generated/*.json`, which for a package that
  # is not in the pinned tree has no entry — `projectInfo.plasma-bigscreen` is a
  # hard error, not a fallback. The newer tree's JSON knows the package; the
  # scope (libs, Qt, KF6, plasma) still comes from the pin.
  mkKdeDerivation = import "${nixpkgs-bigscreen}/pkgs/kde/lib/mk-kde-derivation.nix";
in
{
  nixpkgs.overlays = [
    (final: prev: {
      kdePackages = prev.kdePackages // {
        plasma-bigscreen = (prev.kdePackages.callPackage (mkKdeDerivation prev.kdePackages) { }) {
          pname = "plasma-bigscreen";
          version = "6.7.5";
          src = prev.fetchurl {
            url = "mirror://kde/stable/plasma/6.7.5/plasma-bigscreen-6.7.5.tar.xz";
            hash = "sha256-/QC4/9ahwP1wWKzQYJgRCwC1yh3HIBZwWPrWXSq1C9w=";
          };

          # The launcher and its session file point at plasma-workspace's
          # libexec, which is a different store path than upstream expects.
          postPatch = ''
            # 6.7.5 declares a hard floor of Plasma 6.7 for libplasma,
            # PlasmaActivities(Stats) and LibKWorkspace (PROJECT_DEP_VERSION).
            # Those are release pins, not API requirements — the CMake macros and
            # the C++ used here are unchanged between 6.6.4 and 6.7 — so relax
            # them and let the compiler and the QML runtime be the judge. The
            # Qt/KF6/ECM floors (6.10 / 6.14) are already met by the pin.
            substituteInPlace CMakeLists.txt \
              --replace-fail 'set(PROJECT_DEP_VERSION "6.7.0")' 'set(PROJECT_DEP_VERSION "6.6.0")'

            substituteInPlace bin/plasma-bigscreen-wayland.in \
              --replace-fail @KDE_INSTALL_FULL_LIBEXECDIR@ "${prev.kdePackages.plasma-workspace}/libexec"

            substituteInPlace bin/plasma-bigscreen-wayland.desktop.cmake \
              --replace-fail @CMAKE_INSTALL_FULL_LIBEXECDIR@ "${prev.kdePackages.plasma-workspace}/libexec"
          '';

          extraCmakeFlags = [ (prev.lib.cmakeBool "QT_FIND_PRIVATE_MODULES" true) ];

          extraNativeBuildInputs = [ prev.pkg-config ];

          passthru.providedSessions = [ "plasma-bigscreen-wayland" ];

          extraBuildInputs = [
            prev.kdePackages.qtwebengine
            prev.kdePackages.kdeconnect-kde
            prev.libcec
            prev.libcec_platform
            prev.sdl3
          ];
        };
      };
    })
  ];
}
