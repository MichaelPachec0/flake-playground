{
  lib,
  python3,
  fetchFromGitHub,
  fetchPypi,
  fwup,
  fetchurl,
  libusb1,
  git,
  # for tests
  sby,
  yices,
  yosys,
  nixosInstall ? false,
}: let
  amaranth = python3.pkgs.buildPythonPackage rec {
    pname = "amaranth";
    format = "pyproject";
    version = "0.4.1";

    src = fetchFromGitHub {
      owner = "amaranth-lang";
      repo = "amaranth";
      tag = "v${version}";
      hash = "sha256-lPQw7fAVM7URdyC/9c/UIYsRxVXrLjvHODvhYBdlkkg=";
    };

    postPatch = ''
      substituteInPlace pyproject.toml \
        --replace-fail \
          "pdm-backend~=2.3.0" \
          "pdm-backend>=2.3.0"
    '';

    nativeBuildInputs = [git];
    build-system = [python3.pkgs.pdm-backend];

    dependencies = with python3.pkgs; [
      jschon
      jinja2
      pyvcd
    ];

    nativeCheckInputs = [
      sby
      yices
      yosys
    ];

    pythonImportsCheck = ["amaranth"];
  };
  usb-protocol = python3.pkgs.buildPythonPackage rec {
    pname = "usb_protcol";
    version = "0.9.1";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/a5/0b/f789bcf7f2b5a471d11ae4053ebc09fae8334e8ad6a84489a86a3783e750/usb_protocol-0.9.1.tar.gz";
      hash = "sha256-5v9M+WJ5v7XQEH3ZxuTz3gN2LQ9hNvQsSwJH4H3S/iQ=";
    };
    pyproject = true;
    nativeBuildInputs = with python3.pkgs; [
      construct
    ];
    buildInputs = with python3.pkgs; [
      setuptools
      setuptools-git-versioning
    ];
  };
  luna-usb = python3.pkgs.buildPythonPackage rec {
    pname = "luna-usb";
    version = "0.1.3";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/c8/a5/434d797b80ab8be6db2ebba04797c04548a848749632d72fbddfd384b8d4/luna_usb-0.1.3.tar.gz";
      hash = "sha256-h4wBZfkvaFYZCr19y85AXVbmTu7TKqsUrD76Nh5UEeU=";
    };
    pyproject = true;
    buildInputs = with python3.pkgs; [
      setuptools
      setuptools-git-versioning
    ];
    dependencies = [
      python3.pkgs.libusb1
    ];
    propagatedBuildInputs = with python3.pkgs;
      [
        pyusb
        pyvcd
        libusb1
        pyserial
      ]
      ++ [
        usb-protocol
        amaranth
      ];
  };
  apollo-fpga = python3.pkgs.buildPythonPackage rec {
    pname = "apollo-fpga";
    version = "1.1.1";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/10/46/a453246e1b66609bea15a182c137789ff36bbe2bdc84fc7f8eff26dc4e48/apollo_fpga-1.1.1.tar.gz";
      hash = "sha256-SCLVDBd1GiHwFHvO62UJcyJHNQWLi3Zh5JoGT8Rkbt8=";
    };
    pyproject = true;
    buildInputs = with python3.pkgs; [
      setuptools
      setuptools-git-versioning
    ];
    # nativeBuildInputs = with python3.pkgs; [
    #
    # ];
    propagatedBuildInputs = with python3.pkgs; [
      pyusb
      pyvcd
      prompt-toolkit
      pyxdg
      deprecation
    ];
  };
  luna-soc = python3.pkgs.buildPythonPackage rec {
    pname = "luna-soc";
    version = "0.2.2";
    pyproject = true;
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/dc/f8/93eafccb7790f80c45bdbf55cf4d69a1f1e8f345ea97c14524f907143930/luna_soc-0.2.2.tar.gz";
      hash = "sha256-Upaq+Gu0LI/2HlduHMl6kBlJyGcnoC/p1iHDEBGE93o=";
    };
    dependencies = [
      luna-usb
    ];
    buildInputs = with python3.pkgs; [
      setuptools
      setuptools-git-versioning
    ];
  };
in
  python3.pkgs.buildPythonApplication rec {
    pname = "cynthion";
    version = "0.1.8";
    src = fetchPypi {
      inherit pname version;
      hash = "sha256-eFPyoSs1NxzyBBV/7MAuEbo+cPL3jBg4DPVwift6dPw=";
    };
    pyproject = true;
    buildInputs = with python3.pkgs; [
      setuptools
      setuptools-git-versioning
    ];
    nativeBuildInputs = [
      fwup
    ];
    postPatch =
      if nixosInstall
      then ''
        substituteInPlace src/commands/cynthion_setup.py \
        --replace-fail \
              "        _install_udev(args)" \
              "        logging.info(\"✅ NixOS has already took care of setup process.\n   Please verify with cythion setup --check\")"
      ''
      else "";
    propagatedBuildInputs =
      [
        usb-protocol
        luna-usb
        apollo-fpga
        amaranth
        luna-soc
      ]
      ++ (with python3.pkgs; [
        pygreat
        tomli
        construct
        pyfwup
        tabulate
      ]);
  }
