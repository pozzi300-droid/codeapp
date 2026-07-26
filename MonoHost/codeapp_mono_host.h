#ifndef CODEAPP_MONO_HOST_H
#define CODEAPP_MONO_HOST_H

#ifdef __cplusplus
extern "C" {
#endif

__attribute__((visibility("default"))) int codeapp_mono_exec(
    const char *assembly_search_path,
    const char *assembly_path,
    int argc,
    char **argv,
    int stdout_fd,
    int stderr_fd);

#ifdef __cplusplus
}
#endif

#endif
