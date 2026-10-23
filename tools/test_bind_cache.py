#!/usr/bin/env python3
"""Bindings already in effect are not bound again (plugin/nvmtl_bind_cache.h). tools/test_bind_cache.c runs random
command streams through the header against a model of Vulkan's command-buffer binding state: every draw must see the
index and vertex bindings (and, under a dynamic-stride pipeline, the strides) it asked for. Negative controls must fail:
a header that ignores the index type, one that never records, one that ignores the vertex stride, a record kept across a
new command buffer and one kept across a pipeline change. The source checks hold the plugin to the header's
assumptions: every vkCmdBindIndexBuffer, vkCmdBindVertexBuffers(2) and graphics vkCmdBindPipeline goes through it, and
nvmtl_vk_cmd_begin clears the record with the rest of nvk_cmdbuf. Needs a C compiler only."""
import os
import pathlib
import re
import shutil
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
header = (root / 'plugin/nvmtl_bind_cache.h').read_text()
vk = (root / 'plugin/nvmtl_vk.c').read_text()
vkh = (root / 'plugin/nvmtl_vk.h').read_text()


def run(hdr, *args):
    with tempfile.TemporaryDirectory() as d:
        (pathlib.Path(d) / 'nvmtl_bind_cache.h').write_text(hdr)
        exe = pathlib.Path(d) / 't'
        cc = os.environ.get('CC') or shutil.which('cc') or shutil.which('clang') or shutil.which('gcc')
        assert cc, 'no C compiler'
        c = subprocess.run([cc, '-std=c11', '-O1', '-Wall', '-Werror', '-I', d, '-o', str(exe), str(root / 'tools/test_bind_cache.c')],
                           capture_output=True, text=True)
        assert c.returncode == 0, c.stderr
        r = subprocess.run([str(exe), *args], capture_output=True, text=True, timeout=120)
        return r.returncode, r.stdout + r.stderr


# the plugin keeps to the header's assumptions
assert vk.count('pvkCmdBindIndexBuffer(') == 1, 'a vkCmdBindIndexBuffer outside nvmtl_bind_index'
fn = vk[vk.index('static void nvmtl_bind_index('):]
fn = fn[:fn.index('\n}\n')]
assert 'pvkCmdBindIndexBuffer(' in fn and 'nvmtl_bc_index_same(&c->bind,' in fn
assert vk.count('nvmtl_bind_index(c, idx, ') == 2, 'both indexed draws (direct and indirect) bind through nvmtl_bind_index'
assert vk.count('pvkCmdBindVertexBuffers(c->cb') == 1 and vk.count('pvkCmdBindVertexBuffers2(c->cb') == 1
vin = vk[vk.index('int nvmtl_vk_cmd_vertex_inputs('):]
vin = vin[:vin.index('\n}\n')]
assert 'if (!nvmtl_bc_vertex_same(&c->bind, i, sl->h, off, 0, 0)) pvkCmdBindVertexBuffers(' in vin
assert 'if (!nvmtl_bc_vertex_same(&c->bind, i, sl->h, off, 1, st)) pvkCmdBindVertexBuffers2(' in vin
assert len(re.findall(r'pvkCmdBindPipeline\([^,]*, VK_PIPELINE_BIND_POINT_GRAPHICS', vk)) == 1, 'a graphics pipeline bound outside nvmtl_vk_cmd_bind_pipeline'
bp = vk[vk.index('void nvmtl_vk_cmd_bind_pipeline(nvk_cmdbuf *c, nvk_pipeline *p) {'):]
bp = bp[:bp.index('\n}\n')]
assert bp.index('pvkCmdBindPipeline(') < bp.index('nvmtl_bc_pipeline_changed(&c->bind);'), 'a pipeline change drops the vertex record'
assert re.search(r'nvmtl_bind_cache bind;[^\n]*\n\s*\} nvk_cmdbuf;', vkh), 'nvk_cmdbuf carries the record'
begin = vk[vk.index('int nvmtl_vk_cmd_begin(nvk_queue *q, nvk_cmdbuf *out)'):]
begin = begin[:begin.index('\n}\n')]
assert begin.index('memset(out, 0, sizeof *out);') < begin.index('nvmtl_opaque_AllocateCommandBuffers'), \
    'nvmtl_vk_cmd_begin must clear nvk_cmdbuf (and so the record) before the new command buffer exists'
assert len(re.findall(r'(?:->|\.)cb = (?!NULL)', vk)) == 0, 'a command buffer is swapped into nvk_cmdbuf outside nvmtl_vk_cmd_begin'
print('source: every index, vertex and graphics pipeline bind goes through the record; it is cleared for every new command buffer')

rc, out = run(header)
print(out.strip())
assert rc == 0 and out.rstrip().endswith('ok'), 'the bind record changed what a draw sees:\n' + out

controls = {
    'ignores the index type': header.replace('&& bc->ib_type == type) { bc->skipped++; return 1; }', ') { bc->skipped++; return 1; }'),
    'never records': header.replace('bc->ib = buf; bc->ib_off = off; bc->ib_type = type; bc->ib_on = 1;', 'bc->ib_on = 1;'),
    'ignores the vertex stride': header.replace('\n        && bc->vb_stride[slot] == stride) {', ') {'),
}
for name, bad in controls.items():
    assert bad != header, name
    rc, out = run(bad)
    assert rc != 0, 'negative control passed: ' + name
    print('control fires (%s)' % name)
rc, out = run(header, 'no-reset')
assert rc != 0, 'negative control passed: record kept across a new command buffer'
print('control fires (record kept across a new command buffer)')
rc, out = run(header, 'no-pipeline-drop')
assert rc != 0, 'negative control passed: vertex record kept across a pipeline change'
print('control fires (vertex record kept across a pipeline change)')
print('bind cache: all arms pass')
