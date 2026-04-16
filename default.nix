let
  # packer version for afl++ v4.35c
  version = "7967b43";
in
{
  stdenv,
  lib,
  callPackage,
  fetchFromGitHub,
  cpio,
  gzip,
  glibc,
  pkgsi686Linux,
  pax-utils,
  makeWrapper,
  python3,
  packerSrc ? fetchFromGitHub {
    owner = "nyx-fuzz";
    repo = "packer";
    rev = version;
    hash = "sha256-Qyf5+sckDo9ZpCIRPPM9B6lBdPcEv1LRhIzgYGFKfR4=";
  },
  qemuNyxSrc ? fetchFromGitHub {
    owner = "ekzyis";
    repo = "QEMU-Nyx";
    rev = "d8d971c8bc";
    hash = "sha256-Y6wSdZo+UBeOvjcEvfYOEzUzV6vXBYPFPzF8HXo8Fd0=";
  },
}:

# this derivation assumes x86_64-linux
assert stdenv.targetPlatform.system == "x86_64-linux";

let
  python3WithPkgs = python3.withPackages (ps: [ ps.msgpack ps.jinja2 ]);
  qemuNyx = callPackage ("${qemuNyxSrc}/default.nix") { };
in
stdenv.mkDerivation {
  pname = "nyx-packer";
  inherit version;

  src =
    if builtins.typeOf packerSrc == "path" then
      lib.cleanSource packerSrc
    else
      packerSrc;

  patches = [
    # this patch does following things:
    #   * write default config to ~/.nyx/nyx.ini because nix store is read-only
    #   * fix https://github.com/nyx-fuzz/packer/issues/35
    #   * apply Matt Morehouse's patch (https://github.com/nyx-fuzz/packer/pull/34)
    ./packer.patch
  ];

  strictDeps = true;

  # compile_64.sh / compile_loader use -O0; _FORTIFY_SOURCE needs optimization
  hardeningDisable = [ "fortify" ];

  nativeBuildInputs = [
    cpio
    gzip
    makeWrapper
  ];

  buildInputs = [
    glibc
    glibc.static
    pkgsi686Linux.glibc
  ];

  dontConfigure = true;

  postPatch = ''
    substituteInPlace packer/common/config.py \
      --replace-fail \
        '"QEMU-PT_PATH": "../../QEMU-Nyx/x86_64-softmmu/qemu-system-x86_64"' \
        '"QEMU-PT_PATH": "${qemuNyx}/bin/qemu-system-x86_64"'

    # fix paths to shared libraries that assume debian FHS
    substituteInPlace linux_initramfs/pack.sh \
      --replace-fail \
        'cp -L /lib/ld-linux.so.2' \
        'cp -L ${pkgsi686Linux.glibc}/lib/ld-linux.so.2' \
      --replace-fail \
        'cp -L /lib/x86_64-linux-gnu/libdl.so.2' \
        'cp -L ${glibc}/lib/libdl.so.2' \
      --replace-fail \
        'cp -L /lib/x86_64-linux-gnu/libc.so.6' \
        'cp -L ${glibc}/lib/libc.so.6' \
      --replace-fail \
        'cp -L /lib64/ld-linux-x86-64.so.2' \
        'cp -L ${glibc}/lib/ld-linux-x86-64.so.2' \
      --replace-fail \
        'cp -L /lib64/libdl.so.2' \
        'cp -L ${glibc}/lib/libdl.so.2' \
      --replace-fail \
        'cp -L /lib64/libc.so.6' \
        'cp -L ${glibc}/lib/libc.so.6' \
      --replace-fail \
        'cp -L /lib32/libc.so.6' \
        'cp -L ${pkgsi686Linux.glibc}/lib/libc.so.6' \
      --replace-fail \
        'cp -L /lib32/libdl.so.2' \
        'cp -L ${pkgsi686Linux.glibc}/lib/libdl.so.2' \
      --replace-fail \
        'cp /lib/x86_64-linux-gnu/libnss_compat.so.2' \
        'cp -L ${glibc}/lib/libnss_compat.so.2' \
      --replace-fail \
        'cp /lib64/libnss_compat.so.2' \
        'cp ${glibc}/lib/libnss_compat.so.2'
  '';

  buildPhase = ''
    runHook preBuild

    pushd packer/linux_x86_64-userspace
    echo "+ bash -e compile_64.sh"
    bash -e compile_64.sh
    popd

    pushd linux_initramfs
    echo "+ bash -e pack.sh"
    bash -e pack.sh
    popd

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    # copy build tree so python scripts can assume regular relative paths
    cp -r . "$out" && chmod -R u+w "$out"

    PATH="${python3WithPkgs}/bin:$PATH" patchShebangs --build $out/packer
    wrapProgram $out/packer/nyx_packer.py \
      --suffix PATH : ${lib.makeBinPath [ pax-utils qemuNyx ]}
    wrapProgram $out/packer/nyx_config_gen.py \
      --suffix PATH : ${lib.makeBinPath [ pax-utils qemuNyx ]}

    runHook postInstall
  '';

  postFixup = ''
    # packer binaries are meant to run inside the vm
    find "$out/packer/linux_x86_64-userspace/bin64" -type f \
      -exec patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 {} \;
  '';

  meta = {
    description = "Nyx packer userspace and initramfs images (init.cpio.gz)";
    license = lib.licenses.agpl3Plus;
    platforms = lib.platforms.x86_64;
  };
}
