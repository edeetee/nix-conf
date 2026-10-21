# Plezy 2.x (Plex + Jellyfin + Emby), overlaid onto the pinned nixpkgs.
#
# Why: the pinned `plezy` is **1.30.0**, which predates Jellyfin support entirely
# (it arrived in 2.0.0, May 2026). The installed app therefore only offers "Sign
# in with Plex" — not a setting, a version. This is the same trick as
# bigscreen-overlay.nix: take the derivation *file* from the newer nixpkgs
# (`inputs.nixpkgs-bigscreen`, used purely as a source tree) and build it here.
#
# The one thing that cannot come from the pin is the Flutter SDK: plezy 2.23.0
# is written against flutter347 (3.47.4) while the pin has 3.41.6, and a Flutter
# app's Dart SDK requirement is a hard constraint, not a preference. Flutter is a
# *build-time* toolchain here, so taking `flutter347` from the newer tree is a
# contained kind of skew — it does not drag a second Qt/plasma/KF6 into the
# system the way the §9.2 whole-scope swap would, and nothing else links it.
#
# If the build fails (Dart/Flutter API drift between 3.47 and the app's pin,
# or missing symbols in the newer engine), the fallback is flatpak from Flathub
# (`services.flatpak.enable` is already on) — see plans/plasma-bigscreen.md.
{ nixpkgs-bigscreen, ... }:
{
  nixpkgs.overlays = [
    (final: prev: {
      plezy = prev.callPackage "${nixpkgs-bigscreen}/pkgs/by-name/pl/plezy/package.nix" {
        flutter347 =
          nixpkgs-bigscreen.legacyPackages.${prev.stdenv.hostPlatform.system}.flutter347;
      };
    })
  ];
}
