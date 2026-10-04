{
  config,
  lib,
  ...
}:

# Turns on the Intel GPU userspace stack, so a media server can transcode on the iGPU instead of the CPU.
#
# It exists because CPU tone mapping of a Dolby Vision Profile 5 file is not viable on the boxes this runs on: with
# `tonemapx` on the CPU an N150 takes about 18 hours to convert one 23-minute 4K episode, and a Ryzen 9 only gets
# that to ~1h40 because the DV reshape does not parallelise. On the same N150 the iGPU does it in minutes.
#
# It is deliberately just the ENABLEMENT. The Intel driver packages themselves are the hardware module's job:
# nixos-hardware's `common/gpu/intel` - which the `gmktec-nucbox-g3-plus` profile imports, so gmktec already has it -
# adds `intel-media-driver`, `intel-compute-runtime` and `vpl-gpu-rt` to `hardware.graphics.extraPackages`, but it
# never sets `hardware.graphics.enable`. Without this option those packages sit unused and `/run/opengl-driver` is
# never created, which is exactly the state gmktec1 was in. On a board whose hardware module does not stage them,
# the drivers have to be added to `hardware.graphics.extraPackages` as well.
{
  options.setup.intelGpu = {
    enable = lib.mkEnableOption ''
      the Intel GPU graphics stack (VAAPI, QSV, OpenCL) for hardware video transcoding.

      Leave it off on a machine without Intel graphics: it installs the `linux-firmware` closure and creates
      `/run/opengl-driver`, both of which are dead weight there.
    '';

    # Alder Lake-N (N100/N150/N97) needs this for Vulkan, not for QSV or OpenCL, so it is off by default.
    #
    # Mesa's ANV refuses to load without the kernel context-isolation uAPI, and the `i915` driver does not report
    # it on these parts: `VK_ERROR_INCOMPATIBLE_DRIVER`, "Vulkan requires context isolation for Intel(R) Graphics
    # (ADL-N)". The `xe` driver hardcodes support, so binding the iGPU to it is the only Vulkan fix - and `xe` is
    # still experimental on these platforms, which is why this is a separate switch and not part of `enable`. If
    # only OpenCL (`tonemap_opencl`) is needed, leave it off.
    forceXe = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Bind the Intel GPU to the experimental `xe` driver instead of `i915`, by force-probing it. Needed for
        Vulkan (`libplacebo`) on Alder Lake-N. Does nothing unless `xePciId` is also set.
      '';
    };

    xePciId = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "46d4";
      description = ''
        PCI device id of the iGPU, without the vendor prefix, used by `forceXe`. It is the second half of the
        `8086:<id>` that `lspci -nn` prints; an N150 is `46d4`. Nothing happens while it is null.
      '';
    };
  };

  config = lib.mkIf config.setup.intelGpu.enable {
    hardware.graphics.enable = true;

    # The iGPU's GuC and HuC firmware, without which Quick Sync and the compute runtime never come up. It is free
    # to redistribute but lives in the firmware licence category, so it is enabled explicitly rather than relying
    # on `allowUnfree`.
    hardware.enableRedistributableFirmware = true;

    boot.kernelParams =
      lib.optionals (config.setup.intelGpu.forceXe && config.setup.intelGpu.xePciId != null)
        [
          "i915.force_probe=!${config.setup.intelGpu.xePciId}"
          "xe.force_probe=${config.setup.intelGpu.xePciId}"
        ];

    assertions = [
      {
        assertion = !config.setup.intelGpu.forceXe || config.setup.intelGpu.xePciId != null;
        message = "setup.intelGpu.forceXe is set without setup.intelGpu.xePciId, so no driver would be force-probed.";
      }
    ];
  };
}
