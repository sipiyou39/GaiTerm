# Teddy Voice

This directory contains the voice layer embedded in Teddy CLI.

It is intentionally vendored inside the canonical application repository so a
fresh clone, CI build, and signed release never depend on a sibling project on
the developer's machine. Teddy CLI owns the only application lifecycle; this
directory contains reusable voice services and views, not another app target.
