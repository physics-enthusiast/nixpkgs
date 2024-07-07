{ stdenv
, buildPackages
, lib
, zlib
, which
, bison
, flex
, bc
, python3
}:

let
  pname = "frankenlibc";
  version = "4.19";  #version of the kernel
in
stdenv.mkDerivation {
  inherit pname version;
    
  src = buildPackages.fetchFromGitHub {
    owner = "physics-enthusiast";
    repo = "frankenlibc";
    rev = "7ed672ed9ba31a6e39ba15f82902016b2f49d8a5";
    fetchSubmodules = true;
    sha256 = "sha256-4yJ31OK8RxJEuUHldZ7ip8sEvwPZwB4SyU+ub7m4218=";
  };

  buildInputs = [ zlib ];

  nativeBuildInputs = [ which bison flex bc python3 ];
  
  postPatch = ''
    patchShebangs --build ./
    substituteInPlace build.sh \
      --replace-fail '/bin/echo' 'echo' \
      --replace-fail '#!/bin/sh' '#!${pkgs.stdenv.shell}' \
      --replace-fail '-static' '''
    substituteInPlace Makefile \
      --replace-fail 'build.sh' "./build.sh -d $out -k linux notest"
    substituteInPlace src/build.sh \
      --replace-fail '/bin/pwd' 'pwd'
    substituteInPlace linux/tools/lkl/Makefile.autoconf \
      --replace-fail '/bin/echo' 'echo'
  '';

  env.NIX_CFLAGS_COMPILE = toString [
    "-Wno-error=maybe-uninitialized"
    "-U_FORTIFY_SOURCE"
  ];

  enableParallelBuilding = true;

  dontInstall = true;

  meta = {
    description = "Tools for running rump unikernels in userspace";
    homepage = "https://github.com/ukontainer/frankenlibc";
    license = licenses.gpl2Only;
  };
};
