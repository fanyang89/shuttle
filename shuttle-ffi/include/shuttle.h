#ifndef SHUTTLE_H
#define SHUTTLE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Run in a dedicated process. Callbacks return NULL or a static error name.
 * Each iteration owns its objects. Join each child once before its context
 * expires. Free each object once, after its last user has finished. */
typedef const char *(*shuttle_callback)(void *);
void shuttle_run(shuttle_callback, size_t iterations, const uint64_t *seed,
                 const char *encoded_replay, size_t max_steps);
struct shuttle_task;
struct shuttle_task *shuttle_spawn(shuttle_callback, void *);
void shuttle_join(struct shuttle_task *);
void shuttle_detach(struct shuttle_task *);
void shuttle_yield(void);
struct shuttle_mutex;
struct shuttle_mutex *shuttle_mutex_new(void);
void shuttle_mutex_free(struct shuttle_mutex *);
void shuttle_mutex_lock(struct shuttle_mutex *);
bool shuttle_mutex_try(struct shuttle_mutex *);
void shuttle_mutex_unlock(struct shuttle_mutex *);
struct shuttle_u32;
struct shuttle_u32 *shuttle_u32_new(uint32_t);
void shuttle_u32_free(struct shuttle_u32 *);
uint32_t shuttle_u32_load(struct shuttle_u32 *);
void shuttle_u32_store(struct shuttle_u32 *, uint32_t);
uint32_t shuttle_u32_swap(struct shuttle_u32 *, uint32_t);
uint32_t shuttle_u32_add(struct shuttle_u32 *, uint32_t);
uint32_t shuttle_u32_cas(struct shuttle_u32 *, uint32_t, uint32_t);
#endif
