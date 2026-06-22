"""Caveman compress scripts (pure-Zig runtime).

The compression / detection / validation pipeline was migrated to Zig
(the ``caveman-compress``, ``caveman-detect`` and ``caveman-compress-validate``
binaries). The former Python modules (``cli``, ``compress``, ``detect``,
``validate``) were retired in the R6.4 pure-Zig cutover.

Only ``benchmark`` survives here as a dev-only token-accounting helper used to
regenerate the README benchmark table; it is not on the user install path.
"""

__all__ = ["benchmark"]

__version__ = "1.0.0"
