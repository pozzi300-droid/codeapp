#include <mono/jit/jit.h>
#include <mono/metadata/assembly.h>
#include <mono/metadata/mono-config.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    const char *assembly_search_path;
    const char *assembly_path;
    int argc;
    char **argv;
    int stdout_fd;
    int stderr_fd;
    int result;
    int complete;
} CodeAppMonoRequest;

static MonoDomain *codeapp_domain;
static pthread_t codeapp_mono_thread;
static pthread_once_t codeapp_worker_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t codeapp_worker_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t codeapp_request_ready = PTHREAD_COND_INITIALIZER;
static pthread_cond_t codeapp_request_complete = PTHREAD_COND_INITIALIZER;
static CodeAppMonoRequest *codeapp_request;
static int codeapp_worker_started;
static int codeapp_worker_failed;

static int codeapp_run_request(CodeAppMonoRequest *request) {
    fflush(NULL);
    int saved_stdout = dup(STDOUT_FILENO);
    int saved_stderr = dup(STDERR_FILENO);
    if (saved_stdout < 0 || saved_stderr < 0 ||
        dup2(request->stdout_fd, STDOUT_FILENO) < 0 ||
        dup2(request->stderr_fd, STDERR_FILENO) < 0) {
        if (saved_stdout >= 0) close(saved_stdout);
        if (saved_stderr >= 0) close(saved_stderr);
        return 74;
    }

    int result = 70;
    if (!codeapp_domain) {
        setenv("DOTNET_SYSTEM_GLOBALIZATION_INVARIANT", "1", 1);
        mono_set_assemblies_path(request->assembly_search_path);
        mono_config_parse(NULL);
        codeapp_domain = mono_jit_init("CodeApp.CSharp");
        if (!codeapp_domain) {
            fprintf(stderr, "mono_jit_init failed. Enable JIT for Code App in StikDebug.\n");
            goto cleanup;
        }
    }

    MonoImageOpenStatus open_status = MONO_IMAGE_OK;
    MonoAssembly *assembly = mono_assembly_open(request->assembly_path, &open_status);
    if (!assembly) {
        fprintf(stderr, "Mono could not load managed assembly: %s (status %d)\n",
                request->assembly_path, (int)open_status);
        result = 66;
        goto cleanup;
    }

    char **managed_argv = calloc((size_t)request->argc + 2, sizeof(char *));
    if (!managed_argv) {
        result = 71;
        goto cleanup;
    }
    managed_argv[0] = strdup(request->assembly_path);
    for (int i = 0; i < request->argc; i++) managed_argv[i + 1] = request->argv[i];

    result = mono_jit_exec(
        codeapp_domain, assembly, request->argc + 1, managed_argv);

    free(managed_argv[0]);
    free(managed_argv);

cleanup:
    fflush(NULL);
    dup2(saved_stdout, STDOUT_FILENO);
    dup2(saved_stderr, STDERR_FILENO);
    close(saved_stdout);
    close(saved_stderr);
    return result;
}

static void *codeapp_mono_worker(void *unused) {
    (void)unused;

    pthread_mutex_lock(&codeapp_worker_lock);
    codeapp_worker_started = 1;
    pthread_cond_broadcast(&codeapp_request_complete);

    for (;;) {
        while (!codeapp_request) {
            pthread_cond_wait(&codeapp_request_ready, &codeapp_worker_lock);
        }

        CodeAppMonoRequest *request = codeapp_request;
        pthread_mutex_unlock(&codeapp_worker_lock);
        int result = codeapp_run_request(request);
        pthread_mutex_lock(&codeapp_worker_lock);

        request->result = result;
        request->complete = 1;
        codeapp_request = NULL;
        pthread_cond_broadcast(&codeapp_request_complete);
    }
}

static void codeapp_start_mono_worker(void) {
    if (pthread_create(&codeapp_mono_thread, NULL, codeapp_mono_worker, NULL) != 0) {
        pthread_mutex_lock(&codeapp_worker_lock);
        codeapp_worker_failed = 1;
        pthread_cond_broadcast(&codeapp_request_complete);
        pthread_mutex_unlock(&codeapp_worker_lock);
        return;
    }
    pthread_detach(codeapp_mono_thread);
}

__attribute__((visibility("default"))) int codeapp_mono_exec(
    const char *assembly_search_path,
    const char *assembly_path,
    int argc,
    char **argv,
    int stdout_fd,
    int stderr_fd
) {
    if (!assembly_search_path || !assembly_path || stdout_fd < 0 || stderr_fd < 0) {
        return 64;
    }

    pthread_once(&codeapp_worker_once, codeapp_start_mono_worker);
    pthread_mutex_lock(&codeapp_worker_lock);
    while (!codeapp_worker_started && !codeapp_worker_failed) {
        pthread_cond_wait(&codeapp_request_complete, &codeapp_worker_lock);
    }
    if (codeapp_worker_failed) {
        pthread_mutex_unlock(&codeapp_worker_lock);
        return 70;
    }
    while (codeapp_request) {
        pthread_cond_wait(&codeapp_request_complete, &codeapp_worker_lock);
    }

    CodeAppMonoRequest request = {
        .assembly_search_path = assembly_search_path,
        .assembly_path = assembly_path,
        .argc = argc,
        .argv = argv,
        .stdout_fd = stdout_fd,
        .stderr_fd = stderr_fd,
        .result = 70,
        .complete = 0,
    };
    codeapp_request = &request;
    pthread_cond_signal(&codeapp_request_ready);

    while (!request.complete) {
        pthread_cond_wait(&codeapp_request_complete, &codeapp_worker_lock);
    }
    int result = request.result;
    pthread_mutex_unlock(&codeapp_worker_lock);
    return result;
}
