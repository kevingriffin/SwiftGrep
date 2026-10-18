# The swift.org release toolchain for macOS. nixpkgs builds Swift from
# source and lags behind (6.3 at most), and SwiftGrep needs 6.4.
{
  lib,
  stdenvNoCC,
  fetchurl,
  cctools,
  ld64,
  xar,
  cpio,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "swift-toolchain";
  version = "6.4.1";

  src = fetchurl {
    url = "https://download.swift.org/swift-${finalAttrs.version}-release/xcode/swift-${finalAttrs.version}-RELEASE/swift-${finalAttrs.version}-RELEASE-osx.pkg";
    hash = "sha256-w05+X7C+S81h3s/UDbF2ZDTYlS1o43rtkLz/ToVHlRw=";
  };

  nativeBuildInputs = [
    xar
    cpio
  ];

  unpackPhase = ''
    runHook preUnpack
    xar -xf "$src"
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    gunzip -c swift-*-osx-package.pkg/Payload | (cd "$out" && cpio -id --quiet)
    # The toolchain has no ld or libtool and uses Xcode's through /usr/bin;
    # Swift Build even runs tools with PATH=...:/usr/bin:/bin. clang and
    # SwiftPM look next to themselves first.
    ln -s ${lib.getExe' ld64 "ld"} "$out/usr/bin/ld"
    ln -s ${lib.getExe' cctools "libtool"} "$out/usr/bin/libtool"
    # Put the tools on PATH at their real location: the driver finds its
    # libraries relative to its path without resolving symlinks, so a bin
    # symlink won't do.
    mkdir -p "$out/nix-support"
    echo "addToSearchPath PATH $out/usr/bin" > "$out/nix-support/setup-hook"
    runHook postInstall
  '';

  # The binaries are signed and notarized; stripping or patching them would
  # invalidate the signatures. This also skips installing a `setupHook`,
  # hence the hand-written one above.
  dontFixup = true;

  meta = {
    description = "Swift toolchain from swift.org";
    homepage = "https://www.swift.org";
    license = lib.licenses.asl20;
    platforms = [ "aarch64-darwin" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
