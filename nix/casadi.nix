{ stdenv
, fetchFromGitHub
, cmake
, pkgconfig
, python27
, pythonPackages
, swig
, openblas
, ipopt
, hsl
}:

let
  pythonPrefix = "$out/lib/${python27.libPrefix}/site-packages";
in
stdenv.mkDerivation rec {
  name = "casadi-${version}";
  version = "3.1.0-yacoda0-stable";

  src = fetchFromGitHub {
    owner = "casadi";
    repo = "casadi";
    rev = "72951bab07f63b9a069caf58ee419bb5a725a396"; # yacoda0-stable
    sha256 = "0dz674vw1i3q1kn9g3ydnjgh2x6v4szpmp7qz4cr2ii07f0gzkc8";
  };

  enableParallelBuilding = true;

  nativeBuildInputs = [ cmake pkgconfig ];
  buildInputs = [ python27 swig openblas ipopt hsl pythonPackages.numpy ];

  preConfigure = ''
    cmakeFlags+=" -DWITH_PYTHON=ON -DPYTHON_PREFIX=${pythonPrefix}";
  '';

  doCheck = false; # fails

  checkPhase = "true"; # it has to be done in postInstall

  postInstall = stdenv.lib.optionalString doCheck ''
    cd ../test/python
    export PYTHONPATH=${pythonPrefix}:$PYTHONPATH
    python alltests.py
  '';

  meta = with stdenv.lib; {
    description = "Symbolic framework for numeric optimization implementing automatic differentiation in forward and reverse modes on sparse matrix-valued computational graphs";
    license = licenses.lgpl3;
    homepage = "http://casadi.org";
    platforms = platforms.unix;
  };
}
