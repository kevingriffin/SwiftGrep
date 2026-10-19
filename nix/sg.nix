{
  lib,
  stdenvNoCC,
  fetchgit,
  writeText,
  apple-sdk_27,
  swift-toolchain,
}:

let
  # Package.resolved pins the dependencies; this maps each pinned revision to
  # the hash of its source. Keying by revision means a new pin can't reuse an
  # old source through a stale hash: a missing entry gets lib.fakeHash, and
  # the build fails and prints the hash to add.
  hashes = {
    # swift-syntax 603.0.2
    "79e4b74a295b6eb74a8b585e3a39d29e70c1dbd1" = "sha256-zr+2MlGncEu1bEQwUUxlySDx4XOyK+LnX1SRbtm9ERc=";
  };

  pins = (lib.importJSON ../Package.resolved).pins;

  fetchPin =
    pin:
    fetchgit {
      url = pin.location;
      rev = pin.state.revision;
      hash = hashes.${pin.state.revision} or lib.fakeHash;
    };

  # nixpkgs removes libc++ from the SDK in favor of its own. The macro plugins
  # need Apple's: they link swift-syntax, which deploys back to macOS 10.15,
  # and Swift's back-deployment libraries use libc++. sg itself doesn't.
  sdk = apple-sdk_27.overrideAttrs (old: {
    postInstall = old.postInstall or "" + ''
      cp -d ${old.src}/usr/lib/{libc++.tbd,libc++.1.tbd,libc++abi.tbd} \
        "$out/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/lib/"
    '';
  });

  # SwiftPM's closest thing to vendoring: dependencies in edit mode are read
  # from Packages/<identity>, with no git or network access.
  workspaceState = writeText "workspace-state.json" (
    builtins.toJSON {
      version = 7;
      object = {
        artifacts = [ ];
        prebuilts = [ ];
        dependencies = map (pin: {
          basedOn = null;
          packageRef = {
            inherit (pin) identity kind location;
            name = pin.identity;
          };
          state = {
            name = "edited";
            path = null;
          };
          subpath = pin.identity;
        }) pins;
      };
    }
  );
in

stdenvNoCC.mkDerivation {
  pname = "swiftgrep";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Package.swift
      ../Package.resolved
      ../Sources
      ../Tests
    ];
  };

  nativeBuildInputs = [ swift-toolchain ];
  buildInputs = [ sdk ];

  configurePhase = ''
    runHook preConfigure

    mkdir -p .build Packages
    install -m644 ${workspaceState} .build/workspace-state.json
    ${lib.concatMapStrings (pin: ''
      ln -s ${fetchPin pin} Packages/${pin.identity}
    '') pins}

    swiftpmFlags=(
      # Nix already sandboxes the build, and sandbox-exec can't nest.
      --disable-sandbox
      # Prebuilt swift-syntax is downloaded at build time.
      --disable-experimental-prebuilts
      # SwiftPM ignores $HOME, and the build user's home isn't writable.
      --cache-path "$TMPDIR/swiftpm/cache"
      --config-path "$TMPDIR/swiftpm/config"
      --security-path "$TMPDIR/swiftpm/security"
      # SwiftPM looks up the deployment target for manifests with
      # /usr/bin/xcrun, which needs Xcode. Without it, SwiftPM passes a
      # target with no version, which swiftc rejects. 14.0 is what it finds.
      -Xbuild-tools-swiftc -target -Xbuild-tools-swiftc arm64-apple-macosx14.0
      # Leave out the debug map. It names the build directory, which would
      # make the output's UUID nondeterministic, and the dependencies'
      # sources, which would become runtime dependencies.
      -Xlinker -S
    )

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    swift build --configuration release "''${swiftpmFlags[@]}"
    runHook postBuild
  '';

  # The tests build in debug, apart from the release build. Swift Build links
  # test bundles with XCTest, which only Xcode has, so they use the native
  # build system, which runs swift-testing directly. Debug builds would also
  # sign an entitlement with /usr/bin/codesign.
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    swift test --build-system native --disable-xctest --disable-get-task-allow-entitlement \
      "''${swiftpmFlags[@]}"
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    bin=$(swift build --configuration release "''${swiftpmFlags[@]}" --show-bin-path)
    install -Dm755 "$bin/sg" "$out/bin/sg"
    runHook postInstall
  '';

  # sg links only against the OS; the toolchain and SDK are build-time only.
  allowedReferences = [ ];

  meta = {
    description = "A ripgrep-compatible recursive search tool tuned for APFS";
    mainProgram = "sg";
    platforms = [ "aarch64-darwin" ];
  };
}
