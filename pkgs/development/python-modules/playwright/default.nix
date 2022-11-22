{ lib
, stdenv
, buildPythonPackage
, chromium
, ffmpeg
, firefox-bin
, git
, greenlet
, jq
, nodejs
, fetchFromGitHub
, fetchurl
, fetchzip
, makeFontsConf
, makeWrapper
, pyee
, python
, pythonOlder
, runCommand
, setuptools-scm
, unzip
}:

let
  inherit (builtins) fromJSON readFile listToAttrs;
  inherit (stdenv.hostPlatform) system;
  selectSystem = attrs:
  attrs.${system} or (throw "Unsupported system: ${system}");
  throwSystem = throw "Unsupported system: ${system}";

  driverVersion = "1.28.0";

  driver = let
    suffix = {
      x86_64-linux = "linux";
      aarch64-linux = "linux-arm64";
      x86_64-darwin = "mac";
      aarch64-darwin = "mac-arm64";
    }.${system} or throwSystem;
    filename = "playwright-${driverVersion}-${suffix}.zip";
  in stdenv.mkDerivation {
    pname = "playwright-driver";
    version = driverVersion;

    src = fetchurl {
      url = "https://playwright.azureedge.net/builds/driver/${filename}";
      sha256 = {
        x86_64-linux = "0q4bmn8nh5skhhx7mayyx19lkv44vw38d57j518fcmarvs0mbvml";
        aarch64-linux = "1dq5gxyycn2cqgabviygbw6jbnzgsyz8bl6d5c28bjj83s92k1jv";
        x86_64-darwin = "0g05ssyl2b7k7z88wbhirj2j489adsd0jgin108sh4f1sajyxf1b";
        aarch64-darwin = "0gi1c4shcyhgksa2jdcnb9mmb27zlqgarh7s51k6fbpd7yi62nl9";
      }.${system} or throwSystem;
    };

    sourceRoot = ".";

    nativeBuildInputs = [ unzip ];

    postPatch = ''
      # Use Nix's NodeJS instead of the bundled one.
      substituteInPlace playwright.sh --replace '"$SCRIPT_PATH/node"' '"${nodejs}/bin/node"'
      rm node

      # Hard-code the script path to $out directory to avoid a dependency on coreutils
      substituteInPlace playwright.sh \
        --replace 'SCRIPT_PATH="$(cd "$(dirname "$0")" ; pwd -P)"' "SCRIPT_PATH=$out"

      patchShebangs playwright.sh package/bin/*.sh
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin
      mv playwright.sh $out/bin/playwright
      mv package $out/

      runHook postInstall
    '';

    passthru = {
      inherit filename;
    };
  };

    browser_revs =
    let
      file = fetchurl {
        url =
          "https://raw.githubusercontent.com/microsoft/playwright/v${driverVersion}/packages/playwright-core/browsers.json";
        sha256 = "1w3php0ai38lmbvs5bn8i68hjs0a73pa21xcpna81i6ycicnnhjx";
      };
      raw_data = fromJSON (readFile file);
    in
    listToAttrs (map
      ({ name, revision, ... }: {
        inherit name;
        value = revision;
      })
      raw_data.browsers);

  browsers-mac = stdenv.mkDerivation {
    pname = "playwright-browsers";
    version = driverVersion;

    src = runCommand "playwright-browsers-base" {
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      outputHash = {
        x86_64-darwin = "0z2kww4iby1izkwn6z2ai94y87bkjvwak8awdmjm8sgg00pa9l1a";
      }.${system} or throwSystem;
    } ''
      export PLAYWRIGHT_BROWSERS_PATH=$out
      ${driver}/bin/playwright install
      rm -r $out/.links
    '';

    installPhase = ''
      mkdir $out
      cp -r * $out/
    '';
  };

  browsers-linux = { withFirefox ? true, withChromium ? true }: let
    fontconfig = makeFontsConf {
      fontDirectories = [];
    };
  suffix = selectSystem {
    # Not sure how other system compatibility is, needs trial & error
    x86_64-linux = "ubuntu-20.04";
    aarch64-linux = "ubuntu-20.04-arm64";
    x86_64-darwin = "mac";
    aarch64-darwin = "mac-arm64";
  };

  upstream_firefox = fetchzip {
    url =
      "https://playwright.azureedge.net/builds/firefox/${browser_revs.firefox}/firefox-${suffix}.zip";
    sha256 = "sha256-Tyxud1LNqq2wNyqAcNeyb6iIzvhto5mrejay/DlXKEM=";
    stripRoot = true;
  };
  in runCommand ("playwright-browsers"
    + lib.optionalString (withFirefox && !withChromium) "-firefox"
    + lib.optionalString (!withFirefox && withChromium) "-chromium")
  {
    nativeBuildInputs = [
      makeWrapper
      jq
    ];
  } (''
    BROWSERS_JSON=${driver}/package/browsers.json
  '' + lib.optionalString withChromium ''
    CHROMIUM_REVISION=$(jq -r '.browsers[] | select(.name == "chromium").revision' $BROWSERS_JSON)
    mkdir -p $out/chromium-$CHROMIUM_REVISION/chrome-linux

    # See here for the Chrome options:
    # https://github.com/NixOS/nixpkgs/issues/136207#issuecomment-908637738
    makeWrapper ${chromium}/bin/chromium $out/chromium-$CHROMIUM_REVISION/chrome-linux/chrome \
      --set SSL_CERT_FILE /etc/ssl/certs/ca-bundle.crt \
      --set FONTCONFIG_FILE ${fontconfig}
  '' + lib.optionalString withFirefox ''
    firefoxoutdir=$out/firefox-${browser_revs.firefox}/firefox
    mkdir -p $firefoxoutdir
    cp -r ${upstream_firefox}/* $firefoxoutdir/

    # patchelf the binary
    wrapper="${firefox-bin}/bin/firefox"
    binary="$(readlink -f $(<"$wrapper" grep '^exec ' | grep -o -P '/nix/store/[^"]+' | head -n 1))"

    interpreter="$(patchelf --print-interpreter "$binary")"
    rpath="$(patchelf --print-rpath "$binary")"

    find $firefoxoutdir/ -executable -type f | while read i; do
      chmod u+w "$i"
      [[ $i == *.so ]] || patchelf --set-interpreter "$interpreter" "$i"
      patchelf --set-rpath "$rpath" "$i"
      chmod u-w "$i"
    done

    # create the wrapper script
    rm $firefoxoutdir/firefox
    <"$wrapper" grep -vE '^exec ' > $firefoxoutdir/firefox
    echo "exec \"$firefoxoutdir/firefox-bin\" \"\$@\"" >> $firefoxoutdir/firefox
    chmod a+x $firefoxoutdir/firefox
  '' + ''
    FFMPEG_REVISION=$(jq -r '.browsers[] | select(.name == "ffmpeg").revision' $BROWSERS_JSON)
    mkdir -p $out/ffmpeg-$FFMPEG_REVISION
    ln -s ${ffmpeg}/bin/ffmpeg $out/ffmpeg-$FFMPEG_REVISION/ffmpeg-linux
  '');
in
buildPythonPackage rec {
  pname = "playwright";
  version = "1.27.1";
  format = "setuptools";
  disabled = pythonOlder "3.7";

  src = fetchFromGitHub {
    owner = "microsoft";
    repo = "playwright-python";
    rev = "v${version}";
    sha256 = "sha256-cI/4GdkmTikoP9O0Skh/0jCxxRypRua0231iKcxtBcY=";
  };

  patches = [
    # This patches two things:
    # - The driver location, which is now a static package in the Nix store.
    # - The setup script, which would try to download the driver package from
    #   a CDN and patch wheels so that they include it. We don't want this
    #   we have our own driver build.
    ./driver-location.patch
  ];

  postPatch = ''
    # if setuptools_scm is not listing files via git almost all python files are excluded
    export HOME=$(mktemp -d)
    git init .
    git add -A .
    git config --global user.email "nixpkgs"
    git config --global user.name "nixpkgs"
    git commit -m "workaround setuptools-scm"

    substituteInPlace setup.py \
      --replace "greenlet==1.1.3" "greenlet>=1.1.3" \
      --replace "pyee==8.1.0" "pyee>=8.1.0" \
      --replace "setuptools-scm==7.0.5" "setuptools-scm>=7.0.5" \
      --replace "wheel==0.37.1" "wheel>=0.37.1"

    # Skip trying to download and extract the driver.
    # This is done manually in postInstall instead.
    substituteInPlace setup.py \
      --replace "self._download_and_extract_local_driver(base_wheel_bundles)" ""

    # Set the correct driver path with the help of a patch in patches
    substituteInPlace playwright/_impl/_driver.py \
      --replace "@driver@" "${driver}/bin/playwright"
  '';


  nativeBuildInputs = [ git setuptools-scm ];

  propagatedBuildInputs = [
    greenlet
    pyee
  ];

  postInstall = ''
    ln -s ${driver} $out/${python.sitePackages}/playwright/driver
  '';

  # Skip tests because they require network access.
  doCheck = false;

  pythonImportsCheck = [
    "playwright"
  ];

  passthru = rec {
    inherit driver;
    browsers = {
      x86_64-linux = browsers-linux { };
      aarch64-linux = browsers-linux { };
      x86_64-darwin = browsers-mac;
      aarch64-darwin = browsers-mac;
    }.${system} or throwSystem;
    browsers-chromium = browsers-linux { withFirefox = false; };
    browsers-firefox = browsers-linux { withChromium = false; };

    tests = {
      inherit driver browsers;
    };
  };

  meta = with lib; {
    description = "Python version of the Playwright testing and automation library";
    homepage = "https://github.com/microsoft/playwright-python";
    license = licenses.asl20;
    maintainers = with maintainers; [ techknowlogick yrd SuperSandro2000 ];
  };
}
