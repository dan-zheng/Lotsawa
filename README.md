# Lotsawa

A parsing library and tool with the essential features of
[MARPA](https://jeffreykegler.github.io/Marpa-web-site/), encoded in pure Swift.

In particular, like MARPA, Lotsawa:

- Parses any context-free grammar in linear time.
- Can handle ambiguous grammars

Lotsawa owes almost everything of value to MARPA and its author, Jeffrey Kegler, for uncovering the
[thread of progress in parsing technology](https://jeffreykegler.github.io/personal/timeline_v3),
gathering it together into one group of algorithms, proving important properties about them, and
contributing some key innovations.  This project exists primarily because MARPA is [missing
functionality](https://github.com/jeffreykegler/libmarpa/issues/117) needed by the [Val
language](https://github.com/val-lang/val) implementation.  Secondary reasons Lotsawa might be
useful

- Lotsawa supports high-level usage from a safe, statically-typed language that compiles to efficient
  native code.
- Lotsawa has a simple build/installation process and no dependencies other than Swift.
- Lotsawa encodes the grammar analysis and recognition algorithms with a relatively small amount of
  high-level code; it may serve as a better reference for understanding the technology than either
  the highly theoretical Marpa paper or from libmarpa's C implementation, which must be extracted
  from a CWeb document.
