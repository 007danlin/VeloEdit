# OVRLEY in VeloEdit

VeloEdit vendors the actual OVRLEY Rust core at upstream revision
`0db9be5f775c6e3716407f4a37175c916b8065f1` and builds the local
`veloedit_ovrley_bridge` executable. The bridge is bundled inside
`VeloEdit.app` and communicates with the Swift application through local JSON
over standard output. Media and telemetry are processed offline.

OVRLEY is licensed under GNU GPL version 3 or later. The upstream license and
source are retained in this directory. VeloEdit-specific bridge code is a
modification dated 2026-08-22 and is distributed under the same GPL terms as
the vendored component.

When a build containing the OVRLEY engine is conveyed to another person, the
distributor must comply with GPL-3.0-or-later, including providing the
corresponding source and preserving notices. Purely private local use is not a
conveyance under the license.
