# Zstandard notice

This directory preserves the BSD license for Zstandard 1.5.7, which `cmake/Zstd.cmake` downloads for the WUA extractor when a system zstd is unavailable (or when bundled zstd is requested). CMake pins the upstream archive URL and SHA-256. The zstd implementation itself is fetched at build time and is not vendored in this source export.
