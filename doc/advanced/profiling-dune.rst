Profiling Dune
==============

.. TODO(diataxis)
   - reference: the CLI
   - howto: profiling a dune build

Dune writes detailed trace data about internal operations (such as command
timing) to ``_build/trace.csexp`` by default. Use ``--trace-file FILE`` to
write to a different location.

To load traces into Chromium's ``chrome://tracing`` or Perfetto_, convert them
to Chrome trace format:

.. code:: console

   $ dune trace cat --chrome-trace > trace.json

For Perfetto specifically, ``dune trace perfetto`` produces its native
protobuf format instead. Enabling the ``graph`` trace category additionally
records build-graph data (rule executions, dependency edges) in a form the
Perfetto UI can explore at scale:

.. code:: console

   $ DUNE_TRACE=+graph dune build
   $ dune trace perfetto -o trace.pb

.. _Perfetto: https://ui.perfetto.dev/
