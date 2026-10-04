# Minimal IPv4 arithmetic for validation and derived addresses.
lib: rec {
  toInt = ip: lib.foldl' (acc: octet: acc * 256 + lib.toInt octet) 0 (lib.splitString "." ip);

  fromInt = n: lib.concatMapStringsSep "." (d: toString (lib.mod (n / d) 256)) [16777216 65536 256 1];

  # "10.0.0.1/24" -> { ip = "10.0.0.1"; prefix = 24; }; a bare address is a /32
  parse = cidr: let
    parts = lib.splitString "/" cidr;
  in {
    ip = builtins.head parts;
    prefix =
      if builtins.length parts == 2
      then lib.toInt (lib.last parts)
      else 32;
  };

  # "a.b.c.d", "a.b.c.d/n" or "a.b.c.d-e.f.g.h" -> { first; last; } as integers
  span = s: let
    ends = lib.splitString "-" s;
    c = parse s;
    size = lib.foldl' (acc: _: acc * 2) 1 (lib.range 1 (32 - c.prefix));
    first = toInt c.ip / size * size;
  in
    if builtins.length ends == 2
    then {
      first = toInt (builtins.head ends);
      last = toInt (lib.last ends);
    }
    else {
      inherit first;
      last = first + size - 1;
    };

  within = outer: inner: let
    o = span outer;
    i = span inner;
  in
    o.first <= i.first && i.last <= o.last;

  overlaps = a: b: let
    sa = span a;
    sb = span b;
  in
    sa.first <= sb.last && sb.first <= sa.last;

  # nodes whose LAN subnet (`address`) contains addr: they can answer ARP for it
  lanNodes = nodes: addr: builtins.filter (n: n.address != null && within n.address addr) nodes;

  # nth address of a network: (host "10.43.0.0/16" 10) == "10.43.0.10"
  host = cidr: n: fromInt ((span cidr).first + n);
}
