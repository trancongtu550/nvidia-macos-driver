#!/usr/bin/env python3
"""The plugin finds its private entry points in NVK and in the translator by name (dlsym), so nothing checks at build
time that they exist or agree. This checks the sources against each other: every NVK entry point the plugin looks up is
exported (visibility default) by nvk/nvk-macos.patch, except the RTX 50 direct-dispatch ones the patch does not carry
and the plugin treats as optional; where the plugin's cast spells the signature, it matches the patch's definition; the
surface record the plugin hands to nvmtl_nvk_stage_import has the layout and version of struct nvmtl_nvk_share (checked
by a C compiler); every translator entry point the plugin looks up is a #[no_mangle] function of translator/wrapper; and
the lists in tools/nm_build_plugin.sh match. Negative controls: a patch without one export, a record with two fields
swapped and a record of another version must each be caught."""
import pathlib
import re
import subprocess
import tempfile
import unittest

root = pathlib.Path(__file__).resolve().parents[1]
patch = (root / 'nvk/nvk-macos.patch').read_text()
plugin = {p.name: p.read_text() for p in sorted((root / 'plugin').iterdir()) if p.suffix in ('.m', '.c', '.h')}
wrapper = (root / 'translator/wrapper/src/lib.rs').read_text()
script = (root / 'tools/nm_build_plugin.sh').read_text()

# The RTX 50 direct machine-code lane: looked up, absent from the published patch, off when missing (NVMTLSass.m).
OPTIONAL_ABSENT = {'nvmtl_nvk_dispatch_sass_v3', 'nvmtl_nvk_sass_image_handle_v1', 'nvmtl_nvk_sass_sampler_handle_v1'}


def nvk_lookups(files):
    names = set()
    for text in files.values():
        names |= set(re.findall(r'dlsym\(g_lib, "((?:nvmtl_nvk|nvkmd)_[A-Za-z0-9_]+)"\)', text))
        names |= set(re.findall(r'dlsym\(h, "(nvmtl_nvk_[A-Za-z0-9_]+)"\)', text))
    return names


def xlate_lookups(files):
    return set(re.findall(r'dlsym\(h, "(nvmtl_(?!nvk_)[A-Za-z0-9_]+)"\)', files['NVMTLLibraryLoad.m']))


def added(text):
    """The added lines of the patch, without their '+'."""
    return '\n'.join(l[1:] for l in text.splitlines() if l.startswith('+') and not l.startswith('+++'))


def exports(text):
    """name -> (return type, [parameter types]) for every visibility("default") function the patch adds."""
    body, out = added(text), {}
    for m in re.finditer(r'__attribute__\(\(visibility\("default"\)\)\)\s*([^;{(]*?)\b([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)', body):
        ret, name, params = m.group(1), m.group(2), m.group(3)
        out[name] = (norm(ret), [norm(strip_name(p)) for p in params.split(',') if p.strip() and p.strip() != 'void'])
    return out


def strip_name(param):
    p = param.strip()
    m = re.match(r'(.*?[\s*])([A-Za-z_][A-Za-z0-9_]*)$', p)
    return m.group(1) if m else p


def norm(t):
    t = ' '.join(t.replace('*', ' * ').split())
    return t.replace('struct nvmtl_nvk_share', 'nvmtl_vram_rec').replace('VkCommandBuffer _cmd', 'VkCommandBuffer')


def plugin_casts(files):
    """name -> (return type, [parameter types]) where the plugin's dlsym cast spells the function type."""
    out = {}
    for text in files.values():
        for m in re.finditer(r'\(\s*([A-Za-z_][A-Za-z0-9_ ]*?)\s*\(\*\)\(([^()]*)\)\)\s*dlsym\(g_lib, "([A-Za-z0-9_]+)"\)', text):
            out[m.group(3)] = (norm(m.group(1)), [norm(p) for p in m.group(2).split(',') if p.strip() and p.strip() != 'void'])
    return out


def plugin_record(files):
    m = re.search(r'typedef struct \{([^}]*)\} nvmtl_vram_rec;', files['nvmtl_vk.c'])
    v = re.search(r'nvmtl_vram_rec r = \{ (\d+),', files['nvmtl_vk.c'])
    return m.group(1), int(v.group(1))


def patch_record(text):
    body = added(text)
    m = re.search(r'struct nvmtl_nvk_share \{([^}]*)\};', body)
    v = re.search(r'#define NVMTL_NVK_SHARE_VERSION (\d+)', body)
    return m.group(1), int(v.group(1))


def record_mismatch(plugin_fields, patch_fields):
    """None when a C compiler finds the two records the same size with the same fields at the same offsets."""
    names = re.findall(r'([A-Za-z_][A-Za-z0-9_]*)\s*[,;]', patch_fields)
    asserts = ''.join('_Static_assert(offsetof(P, %s) == offsetof(struct S, %s), "offset of %s");\n' % (n, n, n) for n in names)
    src = ('#include <stddef.h>\n#include <stdint.h>\ntypedef struct {%s} P;\nstruct S {%s};\n'
           '_Static_assert(sizeof(P) == sizeof(struct S), "size");\n%sint main(void) { return 0; }\n') % (
               plugin_fields, patch_fields, asserts)
    with tempfile.TemporaryDirectory() as d:
        c = pathlib.Path(d) / 'r.c'
        c.write_text(src)
        for cc in ('cc', 'clang', 'gcc'):
            try:
                r = subprocess.run([cc, '-std=c11', '-fsyntax-only', str(c)], capture_output=True, text=True)
            except FileNotFoundError:
                continue
            return None if r.returncode == 0 else r.stderr.strip()[-400:]
    raise unittest.SkipTest('no C compiler')


def no_mangle(text):
    return set(re.findall(r'#\[no_mangle\]\s*pub\s+(?:unsafe\s+)?extern\s+"C"\s+fn\s+([A-Za-z0-9_]+)', text))


def script_list(var):
    return {s.lstrip('!') for s in re.search(var + r'="([^"]*)"', script).group(1).split()}


class AbiContract(unittest.TestCase):
    def test_nvk_entry_points_exported(self):
        want, have = nvk_lookups(plugin), exports(patch)
        self.assertTrue(want, 'no NVK lookups found in plugin/')
        missing = want - set(have)
        print('NVK entry points looked up: %d, exported by the patch: %d, absent: %s' % (
            len(want), len(want & set(have)), ', '.join(sorted(missing)) or 'none'))
        self.assertEqual(missing, OPTIONAL_ABSENT, 'NVK entry points the plugin looks up and the patch does not export')
        sass = plugin['NVMTLSass.m']
        self.assertIn('if (!g_sass_dispatch || !nvmtl_sass_image_fn() || !nvmtl_sass_sampler_fn())', sass,
                      'the plugin no longer turns the direct lane off when these entry points are absent')

    def test_signatures_match(self):
        have, casts = exports(patch), plugin_casts(plugin)
        checked = 0
        for name, (ret, params) in casts.items():
            if name not in have:
                continue
            self.assertEqual((ret, params), have[name], name + ': the plugin casts a different function type')
            checked += 1
        print('signatures compared: %d (%s)' % (checked, ', '.join(sorted(n for n in casts if n in have))))
        self.assertGreaterEqual(checked, 4)

    def test_surface_record(self):
        pf, pv = plugin_record(plugin)
        nf, nv = patch_record(patch)
        self.assertEqual(pv, nv, 'the plugin stages surface record v%d, NVK accepts v%d' % (pv, nv))
        self.assertIsNone(record_mismatch(pf, nf))
        print('surface record: version %d, same layout' % pv)

    def test_translator_entry_points(self):
        want, have = xlate_lookups(plugin), no_mangle(wrapper)
        self.assertTrue(want)
        self.assertEqual(want - have, set(), 'translator entry points the plugin looks up and the wrapper does not export')
        print('translator entry points looked up: %d, all exported' % len(want))

    def test_build_script_lists(self):
        self.assertEqual(script_list('NM_NVK_SYMS') - {'vkGetInstanceProcAddr'}, nvk_lookups(plugin))
        self.assertEqual(script_list('NM_XLATE_SYMS'), xlate_lookups(plugin))

    # negative controls
    def test_control_missing_export(self):
        cut = patch.replace('+__attribute__((visibility("default"))) uint32_t\n+nvmtl_nvk_surface_dirty(',
                            '+uint32_t\n+nvmtl_nvk_surface_dirty(')
        self.assertNotEqual(cut, patch)
        self.assertIn('nvmtl_nvk_surface_dirty', nvk_lookups(plugin) - set(exports(cut)))

    def test_control_swapped_fields(self):
        pf, _ = plugin_record(plugin)
        swapped = pf.replace('uint32_t version, surfaceID, plane, pad; uint64_t size_B;',
                             'uint64_t size_B; uint32_t version, surfaceID, plane, pad;')
        self.assertNotEqual(swapped, pf)
        self.assertIsNotNone(record_mismatch(swapped, patch_record(patch)[0]))

    def test_control_version(self):
        other = patch.replace('+#define NVMTL_NVK_SHARE_VERSION 3', '+#define NVMTL_NVK_SHARE_VERSION 4')
        self.assertNotEqual(other, patch)
        self.assertNotEqual(plugin_record(plugin)[1], patch_record(other)[1])


if __name__ == '__main__':
    unittest.main(verbosity=2)
