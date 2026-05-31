{
  lib,
  pkgs,
  stdenv,
  writeText,
  libepoxy,
  vulkan-headers,
  virglrenderer,
}:

let
  libepoxy-minimal = libepoxy.override {
    x11Support = false;
  };
  virglrenderer-minimal = virglrenderer.overrideAttrs {
    buildInputs = [
      libepoxy-minimal
      vulkan-headers
    ];
    mesonFlags = [ (lib.mesonBool "venus" true) ];
  };

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
        return posix_spawn(&pid, argv[0], NULL, NULL, {argv[0], argv[1], "copy"}, (char*[]){NULL});
      }
      char *socket_dir = argv[1];
      char *socket_name = "nix-graphics-socket";
      char *socket_path = malloc(strlen(socket_dir) + strlen("/") + strlen(socket_name) + 1);
      strcpy(socket_path, socket_dir);
      strcat(socket_path, "/");
      strcat(socket_path, socket_name);
      char *virglrenderer_path = "${virglrenderer-minimal}/bin/virgl_test_server";
      char *virglrenderer_argv = {virglrenderer_path, "--venus", "--no-loop-or-fork", "--socket-path", socket_path, NULL};
    #ifdef __linux__
      char *virglrenderer_envp = {"LD_LIBRARY_PATH=/${stdenv.hostPlatform.libDir}/", NULL};
    #else
      char *virglrenderer_envp = {NULL};
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

  nix-graphics-client = writeText "nix-graphics-client.c" ''
    #include <stdbool.h>
    #include <dirent.h>

    void nix_graphics_wrapper_init() {
      bool start_virglrenderer = false;
      DIR *dir = opendir("/run/opengl-driver");
      if (dir)
        closedir(dir);
        return 0; // We're probably on NixOS (or something acting like it) and have working graphics already
      closedir(dir);
