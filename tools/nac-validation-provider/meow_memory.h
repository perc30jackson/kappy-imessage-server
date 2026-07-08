#ifndef KAPPY_MEOW_MEMORY_H
#define KAPPY_MEOW_MEMORY_H

#include <stddef.h>

// Beeper-style scope: pthread mutex + manual NSAutoreleasePool around NAC calls.
typedef struct kappy_meow_scope kappy_meow_scope;

kappy_meow_scope *kappy_meow_enter(void);
void kappy_meow_leave(kappy_meow_scope *scope);

typedef int (*kappy_meow_fn)(void *ctx);
int kappy_meow_run(kappy_meow_fn fn, void *ctx);

#endif
