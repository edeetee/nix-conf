# Machine-local settings: the WiFi network this box joins.
#
# This file is committed with placeholders and *edited in place* with the real
# values, which is why they stay out of git (an uncommitted change to a tracked
# file is still visible to the flake, while an untracked file would not be). If
# you ever rewrite it: `git diff hosts/sink-pi/local.nix` should show your network,
# and nothing you commit should contain it.
#
# pskRaw is derived from the passphrase with:
#   python3 -c 'import hashlib,sys; print(hashlib.pbkdf2_hmac("sha1", sys.argv[1].encode(), sys.argv[2].encode(), 4096, 32).hex())' PASSPHRASE SSID
# Keeping the derived key here rather than the passphrase means the Nix store
# never contains a password that might be reused elsewhere.
{
  wifi = {
    # NB the two are easy to transpose. `thepasswordispassword` is the *network
    # name* (it is in this Mac's preferred-networks list); `username` is the
    # passphrase. An earlier version had them the other way round, which meant the
    # Pi spent its boot scanning for a network that does not exist.
    ssid = "thepasswordispassword";
    country = "NZ";
    pskRaw = "3eec8fcf3dac70a7b753c2d0960aefc58c3c44525fa52a3c93b65ba1719920c0";
  };
}
