#import <Foundation/Foundation.h>
#include <pthread.h>

#include "meow_memory.h"

struct kappy_meow_scope {
    NSAutoreleasePool *pool;
};

static pthread_mutex_t g_nac_mutex = PTHREAD_MUTEX_INITIALIZER;

kappy_meow_scope *kappy_meow_enter(void) {
    pthread_mutex_lock(&g_nac_mutex);
    kappy_meow_scope *scope = malloc(sizeof(kappy_meow_scope));
    if (!scope) {
        pthread_mutex_unlock(&g_nac_mutex);
        return NULL;
    }
    scope->pool = [[NSAutoreleasePool alloc] init];
    return scope;
}

void kappy_meow_leave(kappy_meow_scope *scope) {
    if (!scope) {
        return;
    }
    [scope->pool drain];
    free(scope);
    pthread_mutex_unlock(&g_nac_mutex);
}

int kappy_meow_run(kappy_meow_fn fn, void *ctx) {
    kappy_meow_scope *scope = kappy_meow_enter();
    if (!scope) {
        return -1;
    }
    int rc = fn(ctx);
    kappy_meow_leave(scope);
    return rc;
}
