#include <mono/jit/jit.h>
#include <mono/metadata/assembly.h>
#include <mono/metadata/mono-config.h>
#include <mono/metadata/threads.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static MonoDomain *codeapp_domain;
static pthread_mutex_t codeapp_mono_lock = PTHREAD_MUTEX_INITIALIZER;

int codeapp_mono_exec(
    const char *assembly_search_path,
    const char *assembly_path,
    int argc,
    char **argv
) {
    if (!assembly_search_path || !assembly_path) {
        fprintf(stderr, "Mono host received an invalid path.\n");
        return 64;
    }

    pthread_mutex_lock(&codeapp_mono_lock);

    if (!codeapp_domain) {
        setenv("DOTNET_SYSTEM_GLOBALIZATION_INVARIANT", "1", 1);
        mono_set_assemblies_path(assembly_search_path);
        mono_config_parse(NULL);
        codeapp_domain = mono_jit_init("CodeApp.CSharp");
        if (!codeapp_domain) {
            fprintf(stderr, "mono_jit_init failed. Enable JIT for Code App in StikDebug.\n");
            pthread_mutex_unlock(&codeapp_mono_lock);
            return 70;
        }
    }

    MonoThread *thread = mono_thread_attach(codeapp_domain);
    MonoAssembly *assembly = mono_domain_assembly_open(codeapp_domain, assembly_path);
    if (!assembly) {
        fprintf(stderr, "Mono could not load managed assembly: %s\n", assembly_path);
        if (thread) mono_thread_detach(thread);
        pthread_mutex_unlock(&codeapp_mono_lock);
        return 66;
    }

    char **managed_argv = calloc((size_t)argc + 2, sizeof(char *));
    if (!managed_argv) {
        if (thread) mono_thread_detach(thread);
        pthread_mutex_unlock(&codeapp_mono_lock);
        return 71;
    }
    managed_argv[0] = strdup(assembly_path);
    for (int i = 0; i < argc; i++) managed_argv[i + 1] = argv[i];

    int result = mono_jit_exec(codeapp_domain, assembly, argc + 1, managed_argv);

    free(managed_argv[0]);
    free(managed_argv);
    if (thread) mono_thread_detach(thread);
    pthread_mutex_unlock(&codeapp_mono_lock);
    return result;
}
