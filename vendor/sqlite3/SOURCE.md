# Vendored SQLite

- Product: SQLite amalgamation
- Version: 3.53.4 (`SQLITE_VERSION_NUMBER` = 3053004)
- Source URL: https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip
- Retrieved: 2026-09-26
- Upstream SHA3-256 (from sqlite.org download page): `628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e`
- Downloaded archive SHA-256: `1e71ddf93849c6a6ecf58b827c0692073d2dd7ee40196158068f7b29f422e87d`
- Extracted `sqlite3.c` SHA-256: `b1dd5d74ec7f29055a6684fa06fb3c2f6821c87dd38f9a458dfd2e8a1db28189`
- Extracted `sqlite3.h` SHA-256: `919e7f2e8ed1d8f56ac17b412b8971c76aa5d1a879752cc6058f75e7d5910e1d`

## Why >= 3.51.3

Zindeks opens the graph database in WAL mode and shares it across processes
(the CLI, the embedded shared library and the MCP server). SQLite 3.51.3
contains the WAL-reset concurrency fix that prevents a checkpoint race from
resetting the WAL while another connection is reading it. The ABI layer
refuses to open when `sqlite3_libversion_number()` is below `3051003`.

Re-vendor with:

```
curl -O https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip
unzip sqlite-amalgamation-3530400.zip
cp sqlite-amalgamation-3530400/sqlite3.{c,h} vendor/sqlite3/
```
