# Home Manager entrypoint for homeserver-edt.
#
# Home Manager is here for exactly one thing: the Plasma settings in kde.nix.
# Nothing that owns the shell, PATH or the user's other dotfiles may be added to
# it — this host is system-configured (packages.nix, modules/common.nix) and HM
# taking over those would make `nixup` and this user's environment less
# predictable, not more. See plans/kde-declarative-settings.md §5.
{ ... }:
{
  home-manager.users.edeetee =
    { ... }:
    {
      # One-time choice; HM keeps defaults from the release named here forever.
      # Matches darwin/home.nix. home.username and home.homeDirectory are filled
      # in from users.users.edeetee by the HM NixOS module — do not set them.
      home.stateVersion = "25.05";

      imports = [ ./kde.nix ];
    };
}
