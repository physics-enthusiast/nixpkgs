{
  lib,
  pkgs,
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
      #include <unistd.h>
      #include <stddef.h>
    	#include <stdlib.h>
    	#include <string.h>
    	#include <spawn.h>
    	#include <sys/types.h>
    	#include <sys/wait.h>

      int main(int argc, char **argv) {
        if (argc < 2) {
    	    return -1;
    	  }
    	  char *socket_dir = argv[1];
    	  char *socket_name = "nix-graphics-socket";
    	  char *socket_path = malloc(strlen(socket_dir) + strlen("/") + strlen(socket_name) + 1);
    	  strcpy(socket_path, socket_dir);
    	  strcat(socket_path, "/");
    	  strcat(socket_path, socket_name);
    	  char *virglrenderer_path = "${virglrenderer-minimal}/bin/virgl_test_server";
    	  char *virglrenderer_argv = {virglrenderer_path, "--venus", "--no-loop-or-fork", "--socket-path", socket_path, NULL};
    	  pid_t pid;
    	  if (posix_spawn(&pid, virglrenderer_path, NULL, NULL, virglrenderer_argv, (char*[]){NULL})) {
    	    return -1;
    	  }
    	  // these are harmless if the preceding function fails, so don't bother with error handling
    	  waitpid(pid, NULL, NULL);
    	  unlink((const char *)socket_path);
    	  rmdir((const char *)socket_dir);
    	  return 0
    	}
  '';
in
  nix-graphics-server
