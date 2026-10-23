// test_bind_cache.c: plugin/nvmtl_bind_cache.h against a model of Vulkan's command-buffer binding state.
// Built and run by tools/test_bind_cache.py (also against broken copies of the header, which must fail).
//
// The model: a new command buffer has no binding; vkCmdBindIndexBuffer sets the index binding and
// vkCmdBindVertexBuffers(2) a vertex buffer binding, which nothing else changes (pipeline binds, render passes and
// barriers leave them alone); the stride given to vkCmdBindVertexBuffers2 is dynamic state that binding a pipeline whose
// stride is static overwrites. The plugin before the cache bound the index buffer before every indexed draw and every
// vertex buffer the pipeline fetches before every draw, so at every draw the bindings in effect must be exactly what that
// draw asked for, and under a pipeline with dynamic strides the strides too. Random command streams (new command
// buffers, pipeline binds among one static-stride and two dynamic-stride pipelines, passes, barriers, draws over a few
// buffers, offsets, index types and strides) are run through the cache; the binds it lets through are applied to the
// model, and every draw checks the model.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nvmtl_bind_cache.h"

typedef struct { const void *buf; uint64_t off; uint32_t type; int set; } ibind;
static ibind model_ib;              // what the command buffer holds
typedef struct { const void *buf; uint64_t off; uint64_t stride; int set, stride_set; } vbind;
static vbind model_vb[NVMTL_BC_NVB];
static int model_pipe = -1;         // bound graphics pipeline: 0 has static strides, 1 and 2 dynamic ones
static unsigned long binds_sent, binds_asked, draws;
static int failures;

static void vk_bind_index(const void *buf, uint64_t off, uint32_t type) { model_ib = (ibind){ buf, off, type, 1 }; binds_sent++; }
static void vk_begin(void) { memset(&model_ib, 0, sizeof model_ib); memset(model_vb, 0, sizeof model_vb); model_pipe = -1; }
static void vk_bind_pipeline(int p) {
    model_pipe = p;
    if (p == 0) for (int i = 0; i < NVMTL_BC_NVB; i++) model_vb[i].stride_set = 0;   // its static strides replace the dynamic ones
}
static void vk_bind_vertex(uint32_t slot, const void *buf, uint64_t off, int dyn, uint64_t stride) {
    model_vb[slot].buf = buf; model_vb[slot].off = off; model_vb[slot].set = 1;
    if (dyn) { model_vb[slot].stride = stride; model_vb[slot].stride_set = 1; }
    binds_sent++;
}

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

// nvmtl_vk_cmd_bind_pipeline: a pipeline already bound is not bound again; a new one drops the vertex record
static int pipe_skip_record_drop;   // negative control: forget to drop the record
static void bind_pipeline(nvmtl_bind_cache *bc, int p) {
    if (model_pipe == p) return;
    vk_bind_pipeline(p);
    if (!pipe_skip_record_drop) nvmtl_bc_pipeline_changed(bc);
}
// one draw's vertex buffers as nvmtl_vk_cmd_vertex_inputs binds them, then the check
static unsigned long vdraws;
static void draw_vertices(nvmtl_bind_cache *bc, uint32_t mask, const void *const *buf, const uint64_t *off, const uint64_t *stride) {
    const int dyn = model_pipe != 0;
    for (uint32_t i = 0; i < NVMTL_BC_NVB; i++) if (mask & (1u << i)) {
        binds_asked++;
        if (!nvmtl_bc_vertex_same(bc, i, buf[i], off[i], dyn, stride[i])) vk_bind_vertex(i, buf[i], off[i], dyn, stride[i]);
    }
    vdraws++;
    for (uint32_t i = 0; i < NVMTL_BC_NVB; i++) if (mask & (1u << i)) {
        const vbind *v = &model_vb[i];
        if (!v->set || v->buf != buf[i] || v->off != off[i] || (dyn && (!v->stride_set || v->stride != stride[i]))) {
            if (failures++ < 5) printf("FAILED: vertex draw %lu (pipeline %d) slot %u asked %p+%llu stride %llu, holds %p+%llu stride %llu (set %d/%d)\n",
                                       vdraws, model_pipe, i, buf[i], (unsigned long long)off[i], (unsigned long long)stride[i],
                                       v->buf, (unsigned long long)v->off, (unsigned long long)v->stride, v->set, v->stride_set);
        }
    }
}

static uint64_t rng = 0x9e3779b97f4a7c15ull;
static unsigned rnd(unsigned n) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return (unsigned)(rng % n); }

int main(int argc, char **argv) {
    const int keep_record_across_begin = argc > 1 && !strcmp(argv[1], "no-reset");   // negative control
    pipe_skip_record_drop = argc > 1 && !strcmp(argv[1], "no-pipeline-drop");         // negative control
    static char buffers[4];
    nvmtl_bind_cache bc; memset(&bc, 0, sizeof bc); vk_begin();
    for (int step = 0; step < 200000; step++) {
        switch (rnd(10)) {
        case 0:   // a new VkCommandBuffer: nvmtl_vk_cmd_begin clears the whole nvk_cmdbuf
            vk_begin();
            if (!keep_record_across_begin) memset(&bc, 0, sizeof bc);
            break;
        case 1: break;   // render pass begin/end, barrier: no change to any binding
        case 2: case 3: bind_pipeline(&bc, (int)rnd(3)); break;
        case 4: case 5: case 6: {
            if (model_pipe < 0) bind_pipeline(&bc, (int)rnd(3));
            const void *vb[NVMTL_BC_NVB]; uint64_t vo[NVMTL_BC_NVB], vs[NVMTL_BC_NVB];
            for (int i = 0; i < NVMTL_BC_NVB; i++) { vb[i] = &buffers[rnd(rnd(4) ? 1 : 4)]; vo[i] = rnd(3) ? 0 : 16u * rnd(3); vs[i] = rnd(4) ? 16 : 32; }
            draw_vertices(&bc, rnd(4) ? 0x3u : (1u << rnd(31)) | 1u, vb, vo, vs);
            break; }
        default:
            draw_indexed(&bc, &buffers[rnd(rnd(4) ? 1 : 4)], rnd(3) ? 0 : 4u * rnd(3), rnd(5) ? 1u : 0u);
        }
    }
    // a run of draws from one buffer, as a compositor frame draws its quads
    memset(&bc, 0, sizeof bc); vk_begin();
    const unsigned long before = binds_sent;
    for (int i = 0; i < 100; i++) draw_indexed(&bc, &buffers[0], 0, 1);
    printf("%lu indexed and %lu vertex draws, %lu binds asked, %lu sent; a run of 100 indexed draws from one buffer sends %lu bind(s)\n",
           draws, vdraws, binds_asked, binds_sent, binds_sent - before);
    if (binds_sent - before != 1) { printf("FAILED: a run from one buffer should bind it once\n"); failures++; }
    // pipeline A (dynamic strides), B (static), back to A with no vertex bind in between: the strides must be bound again
    memset(&bc, 0, sizeof bc); vk_begin();
    { const void *vb[NVMTL_BC_NVB] = { &buffers[0] }; uint64_t vo[NVMTL_BC_NVB] = { 0 }, vs[NVMTL_BC_NVB] = { 16 };
      bind_pipeline(&bc, 1); draw_vertices(&bc, 1, vb, vo, vs);
      bind_pipeline(&bc, 0); bind_pipeline(&bc, 1);
      const unsigned long sent = binds_sent; draw_vertices(&bc, 1, vb, vo, vs);
      printf("dynamic -> static -> dynamic pipeline: %lu vertex bind(s) sent again\n", binds_sent - sent);
      if (binds_sent - sent != 1) { printf("FAILED: the stride a static pipeline replaced must be bound again\n"); failures++; } }
    if (failures) { printf("FAILED: %d draw(s) saw the wrong binding\n", failures); return 1; }
    puts("ok");
    return 0;
}
