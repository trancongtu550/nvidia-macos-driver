// nvmtl_bind_cache.h: buffer bindings already in effect in the command buffer being recorded.
//
// Every indexed draw bound its index buffer again, and every draw bound each vertex buffer its pipeline fetches from,
// even when the binding was the one already in effect (Apple's GL and Core Animation draw many times from the same
// buffers). Vulkan keeps buffer bindings in the command buffer until they are bound again: binding a pipeline, beginning
// or ending a render pass and recording barriers leave them alone. The exception is the vertex stride passed to
// vkCmdBindVertexBuffers2: it is dynamic state, and binding a pipeline whose stride is not dynamic replaces it. So the
// vertex record is dropped whenever the bound graphics pipeline changes (nvmtl_bc_pipeline_changed, called where the
// plugin binds one), whether or not a vertex buffer is bound in between; the index record outlives pipeline changes.
//
// The record lives in nvk_cmdbuf, which nvmtl_vk_cmd_begin clears (memset) for every new VkCommandBuffer, the same
// lifetime as the graphics pipeline and descriptor-set records already kept there. Every vkCmdBindIndexBuffer,
// vkCmdBindVertexBuffers(2) and graphics vkCmdBindPipeline of the plugin goes through these checks, so nothing else can
// change what they record.
// A handle stays valid for comparison: Vulkan requires a buffer bound in a command buffer to outlive it, and the encoder
// keeps every buffer it draws from retained until the command buffer retires, so a handle recorded here cannot be freed
// and handed to another buffer while the record exists.
//
// Pure (no Vulkan), so the equivalence is unit-tested: tools/test_bind_cache.py replays random command streams against
// a model of Vulkan's binding state and checks every draw sees what it would have seen with every bind recorded.

#ifndef NVMTL_BIND_CACHE_H
#define NVMTL_BIND_CACHE_H

#include <stdint.h>

#define NVMTL_BC_NVB 32

typedef struct {
    const void *ib; uint64_t ib_off; uint32_t ib_type, ib_on;
    uint32_t vb_on, vb_dyn;                            // a bit per buffer index: recorded; bound with an explicit stride
    const void *vb[NVMTL_BC_NVB]; uint64_t vb_off[NVMTL_BC_NVB], vb_stride[NVMTL_BC_NVB];
    uint64_t skipped;                                  // binds left out (for statistics only)
} nvmtl_bind_cache;

// The bound graphics pipeline changed: the vertex strides it set may differ from what was recorded.
static inline void nvmtl_bc_pipeline_changed(nvmtl_bind_cache *bc) { bc->vb_on = 0; }

// 1 when vertex buffer index `slot` already holds (buffer, offset) bound the same way: dyn says it was bound with an
// explicit stride (vkCmdBindVertexBuffers2), else without one (vkCmdBindVertexBuffers; stride ignored). 0 otherwise, and
// the caller binds; the record then holds the new binding. An index past the record is never left out.
static inline int nvmtl_bc_vertex_same(nvmtl_bind_cache *bc, uint32_t slot, const void *buf, uint64_t off, int dyn,
                                       uint64_t stride)
{
    if (slot >= NVMTL_BC_NVB) return 0;
    const uint32_t bit = 1u << slot;
    if (!dyn) stride = 0;
    if ((bc->vb_on & bit) && bc->vb[slot] == buf && bc->vb_off[slot] == off && !(bc->vb_dyn & bit) == !dyn
        && bc->vb_stride[slot] == stride) { bc->skipped++; return 1; }
    bc->vb[slot] = buf; bc->vb_off[slot] = off; bc->vb_stride[slot] = stride;
    bc->vb_dyn = dyn ? (bc->vb_dyn | bit) : (bc->vb_dyn & ~bit);
    bc->vb_on |= bit;
    return 0;
}

// 1 when (buffer, offset, type) is the index binding already in effect: the bind can be left out. 0 otherwise, and the
// caller binds; the record then holds the new binding.
static inline int nvmtl_bc_index_same(nvmtl_bind_cache *bc, const void *buf, uint64_t off, uint32_t type)
{
    if (bc->ib_on && bc->ib == buf && bc->ib_off == off && bc->ib_type == type) { bc->skipped++; return 1; }
    bc->ib = buf; bc->ib_off = off; bc->ib_type = type; bc->ib_on = 1;
    return 0;
}

#endif
