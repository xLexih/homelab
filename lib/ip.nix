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

  range = cidr: let
    c = parse cidr;
    size = lib.foldl' (acc: _: acc * 2) 1 (lib.range 1 (32 - c.prefix));
    first = toInt c.ip / size * size;
  in {
    inherit first;
    last = first + size - 1;
  };

  contains = cidr: ip: let
    r = range cidr;
    n = toInt ip;
  in
    n >= r.first && n <= r.last;

  overlaps = a: b: let
    ra = range a;
    rb = range b;
  in
    ra.first <= rb.last && rb.first <= ra.last;

  # nth address of a network: (host "10.43.0.0/16" 10) == "10.43.0.10"
  host = cidr: n: fromInt ((range cidr).first + n);
}
