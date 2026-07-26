#include <mono/jit/jit.h>
#include <mono/metadata/assembly.h>
#include <mono/metadata/mono-config.h>
#include <mono/metadata/threads.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static MonoDomain *codeapp_domain;
static pthread_mutex_t codeapp_mono_lock = PTHREAD_MUTEX_INITIALIZER;

__attribute__((visibility("default"))) int codeapp_mono_exec(
    const char *assembly_search_path,
    const char *assembly_path,
    int argc,
    char **argv,
    int stdout_fd,
    int stderr_fd
) {
    if (!assembly_search_path || !assembly_path || stdout_fd < 0 || stderr_fd < 0) {
        fprintf(stderr, "Mono host received an invalid path.\n");
        return 64;
    }

    pthread_mutex_lock(&codeapp_mono_lock);

    fflush(NULL);
    int saved_stdout = dup(STDOUT_FILENO);
    int saved_stderr = dup(STDERR_FILENO);
    if (saved_stdout < 0 || saved_stderr < 0 ||
        dup2(stdout_fd, STDOUT_FILENO) < 0 || dup2(stderr_fd, STDERR_FILENO) < 0) {
        if (saved_stdout >= 0) close(saved_stdout);
        if (saved_stderr >= 0) close(saved_stderr);
        pthread_mutex_unlock(&codeapp_mono_lock);
        return 74;
    }

    int result = 70;
    MonoThread *thread = NULL;
    int attached_here = 0;

    if (!codeapp_domain) {
        setenv("DOTNET_SYSTEM_GLOBALIZATION_INVARIANT", "1", 1);
        mono_set_assemblies_path(assembly_search_path);
        mono_config_parse(NULL);
        codeapp_domain = mono_jit_init("CodeApp.CSharp");
        if (!codeapp_domain) {
            fprintf(stderr, "mono_jit_init failed. Enable JIT for Code App in StikDebug.\n");
            goto cleanup;
        }
    }

    thread = mono_thread_current();
    if (!thread) {
        thread = mono_thread_attach(codeapp_domain);
        attached_here = thread != NULL;
    }
    if (!thread) {
        fprintf(stderr, "Mono could not attach the command thread.\n");
        goto cleanup;
    }

    MonoImageOpenStatus open_status = MONO_IMAGE_OK;
    MonoAssembly *assembly = mono_assembly_open(assembly_path, &open_status);
    if (!assembly) {
        fprintf(stderr, "Mono could not load managed assembly: %s (status %d)\n",
                assembly_path, (int)open_status);
        result = 66;
        goto cleanup;
    }

    char **managed_argv = calloc((size_t)argc + 2, sizeof(char *));
    if (!managed_argv) {
        result = 71;
        goto cleanup;
    }
    managed_argv[0] = strdup(assembly_path);
    for (int i = 0; i < argc; i++) managed_argv[i + 1] = argv[i];

    result = mono_jit_exec(codeapp_domain, assembly, argc + 1, managed_argv);

    free(managed_argv[0]);
    free(managed_argv);

cleanup:
    fflush(NULL);
    if (attached_here && thread) mono_thread_detach(thread);
    dup2(saved_stdout, STDOUT_FILENO);
    dup2(saved_stderr, STDERR_FILENO);
    close(saved_stdout);
    close(saved_stderr);
    pthread_mutex_unlock(&codeapp_mono_lock);
    return result;
}
