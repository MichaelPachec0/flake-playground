{ fetchFromGitHub, buildGoModule, }:
buildGoModule  {
  pname = "ursh";
  version = "0.0.1-master";

  src = fetchFromGitHub {
    owner = "day50-dev";
    repo = "ursh";
    rev = "fa9d1a4edc526e4174cb7e5a5850058185090e1a";
    hash = "sha256-Zqsv4CVtjJIwnNkfc/+/2abB8MtCXaS202Gwf8iyJWE=";
  } + "/cli";
  vendorHash = "sha256-WtU69DJJh7OFu8J5+23/uYHspg0a8LpHtiOzhhWvdFA=";

}
