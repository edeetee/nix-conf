{pkgs, ...}: {
		boot.initrd.kernelModules = ["amdgpu"];
		services.xserver.videoDrivers = [ "amdgpu" ];
		hardware.opengl.extraPackages = with pkgs; [
				rocm-opencl-icd
						rocm-opencl-runtime
		];

			hardware.opengl.driSupport = true;
		hardware.opengl.driSupport32Bit = true;
		hardware.opengl.enable = true;


		systemd.tmpfiles.rules = [
				"L+    /opt/rocm/hip   -    -    -     -    ${pkgs.rocmPackages.clr}"
						"d /mnt/render 0770 render video - -"
		];

}
