// test_bind_cache.c: plugin/nvmtl_bind_cache.h against a model of Vulkan's command-buffer binding state.
// Built and run by tools/test_bind_cache.py (also against broken copies of the header, which must fail).
//
// The model: a new command buffer has no binding; vkCmdBindIndexBuffer sets the index binding, which nothing else
// changes (pipeline binds, render passes and barriers leave it alone). The plugin before the cache bound the index
// buffer before every indexed draw, so at every draw the binding in effect must be exactly what that draw asked for.
// Random command streams (new command buffers, pipeline binds, passes, barriers, indexed draws over a few buffers,
// offsets and index types) are run through the cache; the binds it lets through are applied to the model, and every
// draw checks the model.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nvmtl_bind_cache.h"

typedef struct { const void *buf; uint64_t off; uint32_t type; int set; } ibind;
static ibind model_ib;              // what the command buffer holds
static unsigned long binds_sent, binds_asked, draws;
static int failures;

static void vk_bind_index(const void *buf, uint64_t off, uint32_t type) { model_ib = (ibind){ buf, off, type, 1 }; binds_sent++; }
static void vk_begin(void) { memset(&model_ib, 0, sizeof model_ib); }

// one indexed draw as nvmtl_vk_cmd_draw_indexed records it
static void draw_indexed(nvmtl_bind_cache *bc, const void *buf, uint64_t off, uint32_t type) {
    binds_asked++;
    if (!nvmtl_bc_index_same(bc, buf, off, type)) vk_bind_index(buf, off, type);
    draws++;
    if (!model_ib.set || model_ib.buf != buf || model_ib.off != off || model_ib.type != type) {
        if (failures++ < 5) printf("FAILED: draw %lu asked for index %p+%llu type %u, the command buffer holds %p+%llu type %u (set %d)\n",
                                   draws, buf, (unsigned long long)off, type, model_ib.buf, (unsigned long long)model_ib.off, model_ib.type, model_ib.set);
    }
}

static uint64_t rng = 0x9e3779b97f4a7c15ull;
static unsigned rnd(unsigned n) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return (unsigned)(rng % n); }

int main(int argc, char **argv) {
    const int keep_record_across_begin = argc > 1 && !strcmp(argv[1], "no-reset");   // negative control
    static char buffers[4];
    nvmtl_bind_cache bc; memset(&bc, 0, sizeof bc); vk_begin();
    for (int step = 0; step < 200000; step++) {
        switch (rnd(10)) {
        case 0:   // a new VkCommandBuffer: nvmtl_vk_cmd_begin clears the whole nvk_cmdbuf
            vk_begin();
            if (!keep_record_across_begin) memset(&bc, 0, sizeof bc);
            break;
        case 1: case 2: break;   // pipeline bind, render pass begin/end, barrier: no change to the index binding
        default:
            draw_indexed(&bc, &buffers[rnd(rnd(4) ? 1 : 4)], rnd(3) ? 0 : 4u * rnd(3), rnd(5) ? 1u : 0u);
        }
    }
    // a run of draws from one buffer, as a compositor frame draws its quads
    memset(&bc, 0, sizeof bc); vk_begin();
    const unsigned long before = binds_sent;
    for (int i = 0; i < 100; i++) draw_indexed(&bc, &buffers[0], 0, 1);
    printf("index: %lu draws, %lu binds asked, %lu sent; a run of 100 draws from one buffer sends %lu bind(s)\n",
           draws, binds_asked, binds_sent, binds_sent - before);
    if (binds_sent - before != 1) { printf("FAILED: a run from one buffer should bind it once\n"); failures++; }
    if (failures) { printf("FAILED: %d draw(s) saw the wrong index binding\n", failures); return 1; }
    puts("ok");
    return 0;
}
