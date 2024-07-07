{ lib
, localSystem, guestSystem, crossSystem, config, overlays, crossOverlays ? []
}:

let
  bootStages = import ../. {
    inherit lib localSystem crossSystem overlays crossOverlays;

    guestSystem = localSystem;
  };

in lib.init bootStages ++ [

  # Regular native packages
  (somePrevStage: lib.last bootStages somePrevStage // {
    # It's OK to change the built-time dependencies
    allowCustomOverrides = true;
  })

  (nativePackages: {
    inherit config overlays;
    selfBuild = false;
    stdenv = nativePackages.stdenv.override (old: rec {
      overrides = _: _: {};
      cc = old.cc.override {
        libc = nativePackages.frankenlibc;
        bintools = old.cc.bintools.override {
          libc = nativePackages.frankenlibc;
        };
      };
    });
  })

]
