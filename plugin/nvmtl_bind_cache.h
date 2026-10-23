// nvmtl_bind_cache.h: buffer bindings already in effect in the command buffer being recorded.
//
// Every indexed draw bound its index buffer again, even when the binding was the one already in effect (Apple's GL and
// Core Animation draw many times from the same buffer). Vulkan keeps the index binding in the command buffer until it is
// bound again: binding a pipeline, beginning or ending a render pass and recording barriers leave it alone.
//
// The record lives in nvk_cmdbuf, which nvmtl_vk_cmd_begin clears (memset) for every new VkCommandBuffer, the same
// lifetime as the graphics pipeline and descriptor-set records already kept there. Every vkCmdBindIndexBuffer of the
// plugin goes through this check, so nothing else can change what it records.
// A handle stays valid for comparison: Vulkan requires a buffer bound in a command buffer to outlive it, and the encoder
// keeps every buffer it draws from retained until the command buffer retires, so a handle recorded here cannot be freed
// and handed to another buffer while the record exists.
//
// Pure (no Vulkan), so the equivalence is unit-tested: tools/test_bind_cache.py replays random command streams against
// a model of Vulkan's binding state and checks every draw sees what it would have seen with every bind recorded.

#ifndef NVMTL_BIND_CACHE_H
#define NVMTL_BIND_CACHE_H

#include <stdint.h>

typedef struct {
    const void *ib; uint64_t ib_off; uint32_t ib_type, ib_on;
    uint64_t skipped;                                  // binds left out (for statistics only)
} nvmtl_bind_cache;

// 1 when (buffer, offset, type) is the index binding already in effect: the bind can be left out. 0 otherwise, and the
// caller binds; the record then holds the new binding.
static inline int nvmtl_bc_index_same(nvmtl_bind_cache *bc, const void *buf, uint64_t off, uint32_t type)
{
    if (bc->ib_on && bc->ib == buf && bc->ib_off == off && bc->ib_type == type) { bc->skipped++; return 1; }
    bc->ib = buf; bc->ib_off = off; bc->ib_type = type; bc->ib_on = 1;
    return 0;
}

#endif
