# Headphone library

`database_v1.jsonl.lzma` is the OPRA headphone EQ database (https://github.com/opra-project/OPRA), the
`dist/database_v1.jsonl` file of commit `0b88ecd4`, compressed with LZMA (xz container, as Apple's Compression
framework reads it). Uncompressed: 12,636,756 bytes, SHA-256
`5c4cf9e2f71c696bf4fc5b4d1a46c57f31c6d0041552c2146fcd1413596fd210`, the same file the project's mirror served on
2026-11-26. It lists 714 vendors, 6,230 products and 12,594 parametric EQ presets (AutoEQ 10,784, oratory1990 1,342,
Rtings/AutoEQ 468).

OPRA's manufacturer, product and EQ data is licensed under CC BY-SA 4.0 and its code under MIT (`LICENSE.md`); the
database includes AutoEQ data under the MIT license (`THIRD_PARTY_LICENSES.md`). `opra_logo.png` is OPRA's logo for
the attribution its README asks for. The files are unchanged apart from the compression.
