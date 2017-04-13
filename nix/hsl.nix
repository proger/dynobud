{ stdenv
, gfortran
, pkgconfig
}:

stdenv.mkDerivation rec {
  name = "hsl-${version}";
  version = "2014.01.17";

  # download this from http://www.hsl.rl.ac.uk/ipopt/
  src = ./coinhsl-archive-2014.01.17.tar.gz;

  enableParallelBuilding = true;

  nativeBuildInputs = [ gfortran pkgconfig ];
  buildInputs = [ ];

  checkPhase = "true"; # it has to be done in postInstall

  meta = with stdenv.lib; {
    description = "Harwell Subroutine Library";
    #license = licenses.todo;
    homepage = "http://www.hsl.rl.ac.uk/";
    platforms = platforms.unix;
  };
}
