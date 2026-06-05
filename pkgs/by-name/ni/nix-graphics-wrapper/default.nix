{
  lib,
  pkgs,
  stdenv,
  writeText,
  writeScript,
  makeSetupHook,
  runCommand,
  runCommandCC,
  targetPackages,
}:

let
  libepoxy-minimal = targetPackages.libepoxy.override {
    x11Support = false;
  };

  virglrenderer-minimal = targetPackages.virglrenderer.overrideAttrs {
    buildInputs = [
      libepoxy-minimal
      targetPackages.vulkan-headers
    ];
    mesonFlags = [ (lib.mesonBool "venus" true) ];
  };

  mesa-virtio = targetPackages.mesa.override (old: {
    # this entire wrapper was designed such that it only comes into play if there isn't already a better option,
    # so it's fine if these are empty
    galliumDrivers = lib.lists.intersectLists old.galliumDrivers [ "zink" ];
    vulkanDrivers = lib.lists.intersectLists old.vulkanDrivers [ "virtio" ];
  });

  mesa-glx = runCommand "nix-graphics-wrapper-glx" { } (''
    libglx_mesa = "${mesa-virtio}/lib/libGLX_mesa.so.0"
    if [ -f $libglx_mesa ]; then
      mkdir -p $out/lib
      ln -s $libglx_mesa $out/lib/libGLX_indirect.so.0
    fi
  '');

  nix-graphics-server = writeText "nix-graphics-server.c" ''
    #include <string.h>
    #include <unistd.h>
    #include <stddef.h>
    #include <stdlib.h>
    #include <spawn.h>
    #include <sys/types.h>
    #include <sys/wait.h>
    int main(int argc, char **argv) {
      pid_t pid;
      if (argc < 3) {
        return -1;
      }
      if (!strcmp((const char *)argv[2], "original")) {
        // setsid, spawn a subprocess and exit to detach ourself from the wrapped binary and avoid affecting its wait()
        setsid();
        return posix_spawn(&pid, argv[0], NULL, NULL, (char*[]){argv[0], argv[1], "copy"}, (char*[]){NULL});
      }
      char *socket_dir = argv[1];
      const char *socket_name = "nix-graphics.sock";
      char *socket_path = calloc(strlen((const char *)socket_dir) + strlen("/") + strlen(socket_name) + 1, 1);
      strcat(socket_path, (const char *)socket_dir);
      strcat(socket_path, "/");
      strcat(socket_path, socket_name);
      char *virglrenderer_path = "${virglrenderer-minimal}/bin/virgl_test_server";
      char *virglrenderer_argv[6] = {virglrenderer_path, "--venus", "--no-loop-or-fork", "--socket-path", socket_path, NULL};
    #ifdef __linux__
      char *virglrenderer_envp[2] = {"LD_LIBRARY_PATH=/${stdenv.hostPlatform.libDir}/", NULL};
    #else
      char *virglrenderer_envp[1] = {NULL};
    #endif
      if (posix_spawn(&pid, virglrenderer_path, NULL, NULL, virglrenderer_argv, virglrenderer_envp)) {
        return -1;
      }
      // these are harmless if the preceding function fails, so don't bother with error handling
      waitpid(pid, NULL, NULL);
      unlink((const char *)socket_path);
      rmdir((const char *)socket_dir);
      return 0
      }
  '';
  
  nix-graphics-server-bin = runCommandCC "nix-graphics-server" {} ''
    $CC ${nix-graphics-server} -o $out
  '';

  nix-graphics-client = writeText "nix-graphics-client.c" ''
    #include <string.h>
    #include <stdlib.h>
    #include <stdbool.h>
    #include <dirent.h>
    #include <spawn.h>
    #include <sys/types.h>
    #include <sys/wait.h>
    #include <vulkan/vulkan.h>

    static const char *concatenate_strings(char *values[]) {
      int len = 1;
      int count = 0;
      for (char **value = values; *value; value++) {
        len += strlen((const char *)*value);
        count++;
      }
      char* out = calloc(len, 1);
      for (int i = 0; i    < count; i++) {
        strcat(out, (const char *)values[i]);
      }
      return (const char *)out;
    }

    static const char *shadow_var_name(const char *name) {
      return concatenate_strings((char*[]){"__NIX_GRAPHICS_", name, NULL});
    }

    /*
     * When setting a driver-search-path-override environment variable, also set a corresponding "shadow" variable
     * with a copy of the value to enable the nix-graphics-client wrapper of child processes to determine if that
     * variable has been modified. No special handling is needed for the case where none of the direct and indirect
     * parent processes are wrapped, since all such variables are unset by default.
     */
    static void setenv_shadowed(const char *name, const char *value) {
      setenv(name, value, 1);
      setenv(shadow_var_name(name), value, 1);
    }

    /*
     * If the value of the real and shadow environment variable are different, that indicates that either another
     * wrapper (nixGL, nix-gl-host, or similar) or the application itself already has a set of drivers they'd
     * like to use. These variables cause the loader to skip it's built-in search path, so whoever changed them
     * presumably has drivers they know for sure will work. Since those drivers are likely faster than ours
     * by virtue of not having the overhead of going through IPC, avoid setting this particular variable and
     * let them handle it.
     */
    static bool is_env_changed(const char *name) {
      char *var = getenv(name);
      char *shadow_var = getenv(shadow_var_name(name));
      if (var == shadow_var) { // both NULL
        return false;
      } else {
        // if either is null the strcmp won't be evaluated because the && operator short-circuits
        return (!var && !shadow_var && strcmp((const char*)var ,(const char*)shadow_var));
      }
    }

    /*
     * If we happen to be in a VM with virtIO-GPU vulkan support, all we need to do is set the driver env vars to
     * get everything working. Otherwise, we also need to start virglrenderer.
     */
    static bool need_virglrenderer() {
      VkApplicationInfo app_info = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "nix-graphics-server",
        .applicationVersion = VK_MAKE_VERSION(1,0,0),
        .apiVersion = VK_API_VERSION_1_4,
      };
      VkInstanceCreateInfo create_info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app_info,
      };
      VkInstance instance = NULL;
      VkResult res = vkCreateInstance(&create_info, NULL, &instance);
      if (res != VK_SUCCESS)
        return true;
      uint32_t count = 0;
      res = vkEnumeratePhysicalDevices(instance, &count, NULL);
      if (res != VK_SUCCESS)
        return true;
      VkPhysicalDevice* devices = calloc(count * sizeof(VkPhysicalDevice));
      res = vkEnumeratePhysicalDevices(vk, &count, physical_devices);
      if (res != VK_SUCCESS)
        return true;
      for (uint32_t i = 0; i < count; i++) {
        VkPhysicalDeviceProperties properties = {};
        vkGetPhysicalDeviceProperties(physical_devices[i], &properties);
        if (properties.deviceType != VK_PHYSICAL_DEVICE_TYPE_CPU)
          return false;
      return true;
    }

    void nix_graphics_wrapper_init() {
      DIR *dir = opendir("/run/opengl-driver");
      if (dir) {
        // We're probably on NixOS (or something acting like it) and have working graphics already
        closedir(dir);
        return 0;
      closedir(dir);
      }

      if (!is_env_changed("VK_DRIVER_FILES") && !getenv("VK_ICD_FILENAMES")) {
        char *vk_add_driver_files = getenv("VK_ICD_FILENAMES");
        char *mesa_icd_path = "${mesa-virtio}/share/vulkan/icd.d";
        if (*vk_add_driver_files) {
          setenv_shadowed("VK_DRIVER_FILES", concatenate_strings((char*[]){mesa_icd_path, ":", vk_add_driver_files, NULL}));
        } else {
          setenv_shadowed("VK_DRIVER_FILES", mesa_icd_path);
        }

        if (need_virglrenderer()) {
          char *tmpdir = getenv("TMPDIR");
          if (!tmpdir || !(*tmpdir)) { // || operator also short-circuits, so no null dereference here
            tmpdir = "/tmp";
          }
          char *template = concatenate_strings((char*[]){tmpdir, "/sockdirXXXXXX", NULL});
          char *socket_dir = mkdtemp(template);
          const char *socket_path = concatenate_strings((char*[]){socket_dir, "/nix-graphics.sock", NULL})
          setenv("VN_DEBUG", "vtest");
          setenv("VTEST_SOCKET_NAME", socket_path);
          pid_t pid;
          char *server_path = ${nix-graphics-server-bin};
          posix_spawn(&pid, server_path, NULL, NULL,  (char*[]){server_path, socket_dir, "original"}, (char*[]){NULL});
          // wait for the server to detach
          waitpid(pid, NULL, NULL);
        }
      }
      
      if (!is_env_changed("LIBGL_DRIVERS_PATH") && !is_env_changed("GBM_BACKENDS_PATH")) {
        setenv_shadowed("LIBGL_DRIVERS_PATH", "${lib.getOutput "lib" mesa-virtio}");
        setenv_shadowed("GBM_BACKENDS_PATH", "${lib.getOutput "lib" mesa-virtio}");
        // If/when mesa merges https://gitlab.freedesktop.org/mesa/mesa/-/merge_requests/31517 for Zink VAAPI support
        // setenv_shadowed("LIBVA_DRIVERS_PATH", "${lib.getOutput "lib" mesa-virtio}");

        char *ld_library_path = getenv("LD_LIBRARY_PATH")
        if (!ld_library_path || !(*ld_library_path)) {
          setenv("LD_LIBRARY_PATH", "${mesa-glx}/lib");
        } else if (!strstr((const char *)ld_library_path, "nix-graphics-wrapper-glx")) {
          setenv("LD_LIBRARY_PATH", concatenate_strings((char*[]){ld_library_path, ":${mesa-glx}/lib", NULL}));
        }
        
        if (!is_env_changed("__EGL_VENDOR_LIBRARY_FILENAMES")) {
          setenv_shadowed("__EGL_VENDOR_LIBRARY_FILENAMES", "${mesa-virtio}/share/glvnd/egl_vendor.d/50_mesa.json");
        }
      }
    }
  '';
  
  nix-graphics-client-lib = runCommandCC "nix-graphics-server" {
    buildInputs = [ targetPackages.vulkan-loader ];
  } ''
    $CC ${nix-graphics-client} -lvulkan -shared -o $out
  '';
in
if stdenv.targetPlatform.isDarwin then
  null
else
  makeSetupHook {
    name = "nix-graphics-wrapper";
    license = lib.licenses.mit;
  } (writeScript "inject-propagated-hook.sh" ''
  
  '')
